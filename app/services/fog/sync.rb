# typed: strict
# frozen_string_literal: true

module Fog
  # Level 1 of the fog integration: read what fog knows
  # through its MCP tools and keep it. Fog samples container stats every ten
  # seconds and health every thirty and keeps both only in memory; Glass is
  # the history fog deliberately does not keep.
  #
  # One pass: the roster (an app in fog is an app in Glass, marked silent
  # until it reports — unless a person removed it from Glass, which
  # `AppSetting#fog_ignored_apps` remembers), container vitals and whether it is up as
  # `fog.container.*` metrics, health transitions and deploys as markers.
  class Sync
    extend T::Sig

    # Container vitals fog reports per app (apps.AppStatus), as metrics.
    VITALS = T.let({
      "cpuPercent" => [ "fog.container.cpu_pct", "percent" ],
      "memUsage" => [ "fog.container.memory_bytes", "bytes" ],
      "memLimit" => [ "fog.container.memory_limit_bytes", "bytes" ],
      "netInBps" => [ "fog.container.net_in_bps", "bytes" ],
      "netOutBps" => [ "fog.container.net_out_bps", "bytes" ],
      "diskReadBps" => [ "fog.container.disk_read_bps", "bytes" ],
      "diskWriteBps" => [ "fog.container.disk_write_bps", "bytes" ]
    }.freeze, T::Hash[String, [ String, String ]])

    # 1 while the container runs and its health check passes, 0 while it
    # does not: uptime is this gauge's mean, and a monitor can hold it to 1.
    UP = "fog.container.up"

    class Result < T::Struct
      const :apps, Integer
      const :created, Integer
      const :points, Integer
      const :markers, Integer
    end

    sig { params(household: Household, client: McpClient, now: Time).returns(Result) }
    def self.call(household:, client:, now: Time.now.utc)
      new(household: household, client: client, now: now).call
    end

    sig { params(household: Household, client: McpClient, now: Time).void }
    def initialize(household:, client:, now:)
      @household = household
      @client = client
      @now = now
      @created = T.let(0, Integer)
      @markers = T.let(0, Integer)
      @settings = T.let(nil, T.nilable(AppSetting))
    end

    sig { returns(Result) }
    def call
      statuses = Array(@client.call_tool("fog_apps_list")["apps"]).grep(Hash)
      points = T.let([], T::Array[Ingest::Records::Metric::Point])
      apps = T.let({}, T::Hash[String, App])
      statuses.each do |status|
        app = app_for(status)
        next if app.nil?

        apps[status["name"].to_s] = app
        points.concat(vitals_for(status))
        note_health(app, status)
        note_deploys(app, status)
        app.update_columns(fog_state: { "rev" => status["currentRev"], "healthy" => status["healthy"], "state" => status["state"], "hosts" => status["hosts"] }) # rubocop:disable Rails/SkipsModelValidations
      end
      write_points(points, apps)
      Result.new(apps: statuses.size, created: @created, points: points.size, markers: @markers)
    end

    private

    # The Glass app for a fog app: matched by fog name, else by slug, else
    # made — silent until it reports, which the Overview says. One a person
    # removed from Glass is not made again: fog still lists it every pass,
    # and a removal has to outlast the minute (Settings › Fog follows it
    # again). Asked at the moment of making, so a removal mid-pass holds.
    sig { params(status: T::Hash[String, T.untyped]).returns(T.nilable(App)) }
    def app_for(status)
      name = status["name"].to_s
      return nil if name.blank? || !App::SLUG_FORMAT.match?(name)

      app = App.adopt_from_fog!(@household, name, create: !settings.fog_ignores?(name))
      @created += 1 if app&.previously_new_record?
      app
    end

    sig { returns(AppSetting) }
    def settings = @settings ||= AppSetting.current

    # A point per vital fog has a fresh reading for. Absent is absent: fog
    # sends nil until its sampler has read the container, and nil stays
    # nil here.
    sig { params(status: T::Hash[String, T.untyped]).returns(T::Array[Ingest::Records::Metric::Point]) }
    def vitals_for(status)
      points = VITALS.filter_map do |field, (metric, unit)|
        value = status[field]
        next unless value.is_a?(Numeric) && value.to_f.finite?

        gauge(status, metric, unit, value.to_f)
      end
      up = up?(status)
      points << gauge(status, UP, nil, up ? 1.0 : 0.0) unless up.nil?
      points
    end

    # Whether fog says the app is up, or nil when that is not a question:
    # an app never deployed, or stopped on purpose, is not an outage and
    # must not count against its uptime.
    sig { params(status: T::Hash[String, T.untyped]).returns(T.nilable(T::Boolean)) }
    def up?(status)
      state = status["state"]
      return nil if !state.is_a?(String) || state.blank? || state == "new"
      return nil if status["desiredState"].is_a?(String) && status["desiredState"] != "running"

      state == "running" && status["healthy"] != false
    end

    sig { params(status: T::Hash[String, T.untyped], metric: String, unit: T.nilable(String), value: Float).returns(Ingest::Records::Metric::Point) }
    def gauge(status, metric, unit, value)
      Ingest::Records::Metric::Point.new(
        ts: Time.at(@now.to_i - (@now.to_i % 10)).utc, name: metric, kind: Telemetry::MetricSeries::Kind::Gauge, unit: unit,
        tags: { "app" => status["name"].to_s, "source" => "fog" }, n: 1, sum: value, min: value, max: value, last: value, sketch: nil
      )
    end

    # Points belong to the app they describe (`apps`, by fog's name, as this
    # pass matched them); the series resolver and the writer are the ingest
    # path's, so a fog vital is a metric like any other.
    sig { params(points: T::Array[Ingest::Records::Metric::Point], apps: T::Hash[String, App]).void }
    def write_points(points, apps)
      points.group_by { |point| point.tags["app"] }.each do |name, group|
        app = apps[name.to_s]
        next if app.nil?

        ids = Ingest::SeriesResolver.resolve(app, group)
        rows = group.zip(ids).map do |point, id|
          { series_id: id, ts: point.ts, n: point.n, sum: point.sum, min: point.min, max: point.max, last: point.last, sketch: nil }
        end
        Telemetry::MetricPoint.insert_all!(rows, returning: false, record_timestamps: false) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    sig { params(app: App, status: T::Hash[String, T.untyped]).void }
    def note_health(app, status)
      healthy = status["healthy"]
      before = app.fog_state["healthy"]
      return if healthy.nil? || before.nil? || healthy == before

      marker(app, healthy ? "Healthy again" : "Health check failing", kind: healthy ? "event" : "incident", attrs: { "fog" => "health" })
    end

    # A rev fog has since deployed: fog_app_get carries the last few deploys
    # with their outcome; each becomes a marker once.
    sig { params(app: App, status: T::Hash[String, T.untyped]).void }
    def note_deploys(app, status)
      rev = status["currentRev"]
      return unless rev.is_a?(Integer) && rev != app.fog_state["rev"]

      detail = @client.call_tool("fog_app_get", { "name" => status["name"].to_s })
      Array(detail["deploys"]).each do |deploy|
        next unless deploy.is_a?(Hash) && deploy["rev"].is_a?(Integer) && deploy["status"].to_s != "running"
        next if marker_exists?(app, deploy["rev"])

        at = deploy_time(deploy)
        title = "Deploy ##{deploy['rev']} #{deploy['status']}#{deploy['actor'].present? ? " by #{deploy['actor']}" : ''}"
        marker(app, title, kind: deploy["status"].to_s == "failed" ? "incident" : "deploy", attrs: { "fog" => "deploy", "rev" => deploy["rev"], "status" => deploy["status"] }, at: at)
      end
    end

    sig { params(deploy: T::Hash[String, T.untyped]).returns(Time) }
    def deploy_time(deploy)
      Time.iso8601(deploy["finishedAt"].presence || deploy["startedAt"].to_s).utc
    rescue ArgumentError
      @now
    end

    sig { params(app: App, rev: Integer).returns(T::Boolean) }
    def marker_exists?(app, rev)
      Telemetry::Marker.where(app_id: app.telemetry_id, source: "fog", ts: (@now - 30.days)..).where("attrs->>'rev' = ?", rev.to_s).exists?
    end

    sig { params(app: App, title: String, kind: String, attrs: T::Hash[String, T.untyped], at: Time).void }
    def marker(app, title, kind:, attrs:, at: @now)
      Telemetry::Partitions.ensure_for!([ "markers" ], at) if at < @now - 86_400
      Telemetry::Marker.insert!({ ts: at, app_id: app.telemetry_id, kind: kind, title: title, release: nil, source: "fog", attrs: attrs }) # rubocop:disable Rails/SkipsModelValidations
      @markers += 1
    end
  end
end
