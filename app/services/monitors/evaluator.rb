# typed: strict
# frozen_string_literal: true

module Monitors
  # One monitor, one evaluation: run its query over its
  # window, compare, apply the hold-down, move the state, and turn a
  # transition into an incident, a marker and a push.
  class Evaluator
    extend T::Sig

    # `context` is the monitor's household's: EvaluateMonitorsJob builds one
    # per household and shares it across that household's monitors.
    sig { params(monitor: MonitorRule, now: Time, context: T.nilable(Query::Context)).void }
    def self.call(monitor, now: Time.now.utc, context: nil)
      new(monitor, now: now, context: context).call
    end

    sig { params(monitor: MonitorRule, now: Time, context: T.nilable(Query::Context)).void }
    def initialize(monitor, now:, context: nil)
      @monitor = monitor
      @now = now
      @context = context
      @app_slug = T.let(nil, T.nilable(String))
      @app_slug_read = T.let(false, T::Boolean)
    end

    sig { void }
    def call
      value = measure
      breached = breached?(value)
      breached = false if breached && in_deploy_grace?
      pending_since = breached ? (@monitor.pending_since&.utc || @now) : nil
      held = breached && !pending_since.nil? && (@now - pending_since).to_f >= @monitor.for_seconds

      next_state = value.nil? && @monitor.kind_enum != MonitorRule::Kind::Absence ? MonitorRule::State::NoData : held ? MonitorRule::State::Alert : MonitorRule::State::Ok
      move(next_state, value, pending_since: pending_since, error: nil)
    rescue Query::Invalid => e
      # A query that no longer compiles is no data — and leaving Alert that
      # way closes the incident like any other exit, or the next alert would
      # open a second one beside it.
      move(MonitorRule::State::NoData, nil, pending_since: nil, error: e.message)
    end

    private

    sig do
      params(next_state: MonitorRule::State, value: T.nilable(Float), pending_since: T.nilable(Time),
        error: T.nilable(String)).void
    end
    def move(next_state, value, pending_since:, error:)
      transition(next_state, value) if next_state != @monitor.state_enum
      @monitor.update!(last_value: value, last_evaluated_at: @now, last_error: error, pending_since: pending_since,
        state: next_state.serialize, state_since: next_state == @monitor.state_enum ? @monitor.state_since : @now)
    end

    # The query's answer over the window: one compute, no groups.
    sig { returns(T.nilable(Float)) }
    def measure
      query = @monitor.query
      compute = @monitor.kind_enum == MonitorRule::Kind::Absence ? "count" : (query["compute"].presence || "count")
      request = Query::Request.from_params(
        "source" => query["source"], "shape" => "table", "from" => (@now - @monitor.window_seconds).to_f, "to" => @now.to_f,
        "filter" => query["filter"].to_s, "compute" => [ compute ], "metric" => query["metric"]
      )
      row = Query::Runner.run(request, context)[:rows].first
      value = row && row[compute]
      value.is_a?(Numeric) ? value.to_f : nil
    end

    sig { params(value: T.nilable(Float)).returns(T::Boolean) }
    def breached?(value)
      case @monitor.kind_enum
      when MonitorRule::Kind::Absence then value.nil? || value <= 0
      else
        return false if value.nil?

        @monitor.comparison_enum == MonitorRule::Comparison::Lt ? value < @monitor.threshold : value > @monitor.threshold
      end
    end

    # A deploy of the monitor's app inside the grace window mutes it: the
    # first minutes after a deploy are a cold cache, not an incident.
    sig { returns(T::Boolean) }
    def in_deploy_grace?
      return false if @monitor.deploy_grace_seconds.zero?

      app_id = app_telemetry_id
      return false if app_id.nil?

      Telemetry::Marker.where(app_id: app_id, kind: Telemetry::Marker::Kind::Deploy.serialize, ts: (@now - @monitor.deploy_grace_seconds)..).exists?
    end

    sig { params(next_state: MonitorRule::State, value: T.nilable(Float)).void }
    def transition(next_state, value)
      if next_state == MonitorRule::State::Alert
        open_incident(value)
      elsif @monitor.state_enum == MonitorRule::State::Alert
        close_incident(value)
      end
    end

    sig { params(value: T.nilable(Float)).void }
    def open_incident(value)
      incident = Incident.create!(household_id: @monitor.household_id, monitor: @monitor, opened_at: @now, peak_value: value, app_slug: app_slug)
      write_marker("#{@monitor.name} alerting", "opened")
      Activity.record(source: "monitors", event: "monitor.alert", severity: Activity::Severity::Warn,
        summary: "#{@monitor.name}: #{@monitor.condition_text} (#{value&.round(3) || 'no data'})", subject: @monitor,
        household_id: @monitor.household_id)
      FogEvents.incident_opened(incident, @monitor, value)
      return unless @monitor.notify

      Notifier.push(title: "Glass: #{@monitor.name}", message: "#{@monitor.condition_text} — now #{value&.round(3) || 'no data'}")
      incident.update!(notified_at: @now)
    end

    sig { params(value: T.nilable(Float)).void }
    def close_incident(value)
      incident = @monitor.open_incident
      incident&.update!(closed_at: @now, peak_value: [ incident.peak_value, value ].compact.max)
      write_marker("#{@monitor.name} recovered", "closed")
      Activity.record(source: "monitors", event: "monitor.recovered", summary: "#{@monitor.name} recovered", subject: @monitor,
        household_id: @monitor.household_id)
      FogEvents.incident_closed(incident, @monitor) if incident
      Notifier.push(title: "Glass: #{@monitor.name} recovered", message: @monitor.condition_text) if @monitor.notify
    end

    sig { params(title: String, phase: String).void }
    def write_marker(title, phase)
      Telemetry::Marker.insert!({ # rubocop:disable Rails/SkipsModelValidations
        ts: @now, app_id: app_telemetry_id, kind: Telemetry::Marker::Kind::Incident.serialize, title: title, release: nil,
        source: "glass", attrs: { "monitor_id" => @monitor.id, "phase" => phase }
      })
    end

    sig { returns(Query::Context) }
    def context
      @context ||= Query::Context.new(T.must(@monitor.household))
    end

    # MonitorRule#app_slug parses the filter; read once per evaluation.
    sig { returns(T.nilable(String)) }
    def app_slug
      return @app_slug if @app_slug_read

      @app_slug_read = true
      @app_slug = @monitor.app_slug
    end

    # The app the monitor names, through the household's context — which
    # already holds every app's id, so this asks the database nothing.
    sig { returns(T.nilable(Integer)) }
    def app_telemetry_id
      slug = app_slug
      slug && context.app_id(slug)
    end
  end
end
