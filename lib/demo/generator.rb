# typed: false
# frozen_string_literal: true

require_relative "fleet"
require_relative "harness"

module Demo
  # Fills a development instance with a week of believable telemetry for the
  # pretend fleet (Demo::Fleet), so the console can be built and looked at
  # without five real apps reporting.
  #
  # Requests, jobs, spans, logs, profiles and markers go through the real
  # ingest builders (Ingest::Batch#add_record → Ingest::Writer) as
  # glass-ingest/1 records — the demo exercises the path real agents use.
  # Only old metric points take a shortcut: a week at ten-second resolution
  # would be millions of rows, so history is written straight into the
  # 5-minute tier, exactly as the rollup would have left it.
  class Generator
    include Harness

    USERS = %w[u_6f1d2a90c3b4e571 u_b83c55d1e07a9f24 u_2a90e4417cd8b356 u_d417f3a86b20c9e5].freeze
    ORIGINS = ([ "lan" ] * 16 + [ "vpn" ] * 3 + [ "tunnel" ]).freeze
    RAW_METRIC_WINDOW = 2 * 3600

    attr_reader :now, :from

    def initialize(days: 7, seed: 20260930, now: Time.now.utc, output: $stdout)
      @now = Time.at(now.to_i - now.to_i % 10).utc
      @from = @now - days * 86_400
      @rng = Random.new(seed)
      @output = output
      # The two stories (see Demo::Fleet).
      @bad_deploy = @now - 26 * 3600
      @fix_deploy = @now - 20 * 3600
      @burst = (@now - 5 * 3600)..(@now - 5 * 3600 + 20 * 60)
      @outage = (@now - 9 * 3600)..(@now - 9 * 3600 + 40 * 60)
    end

    def run!
      household = Household.instance || raise("No household yet — finish setup (or run bin/rails glass:demo:account) first")
      Current.household = household
      apps = Fleet::ALL.to_h { |spec| [ spec, ensure_app(household, spec) ] }
      ensure_partitions

      apps.each do |spec, app|
        say "#{spec.name}…"
        releases = releases_for(spec)
        write_markers(app, spec, releases)
        write_transactions(app, spec, releases)
        write_profiles(app, spec, releases)
        write_metrics(app, spec)
        write_visits(app, spec)
        write_processes(app, spec, releases)
      end
      Fleet::IMAGES.each do |image|
        say "#{image.name}…"
        write_container(ensure_image(household, image), image)
      end
      write_harness(household)
      finish_rollups
      say "done: #{Telemetry::Transaction.count} transactions, #{Telemetry::Span.count} spans, " \
          "#{Telemetry::ModelCall.count} model calls, #{Telemetry::LogLine.count} logs, " \
          "#{Telemetry::ProfileSample.count} profile rows, #{Telemetry::MetricSeries.count} series"
    end

    # One flush window's worth of live records for an app, as wire records:
    # what `glass:demo:live` posts to the real ingest endpoint.
    def live_records(spec, from, to)
      release = releases_for(spec).last[1]
      records = []
      each_transaction(spec, from, to, release_at: ->(_) { release }) do |txn, spans, logs|
        records << txn
        records.concat(spans, logs)
      end
      records.concat(metric_records(spec, from, to))
      records
    end

    def header_for(spec, kind, release)
      { "v" => 1, "sent_at" => Time.now.to_f,
        "process" => { "kind" => kind, "host" => "#{spec.slug}-#{kind}-1", "pid" => kind == "web" ? 7 : 1, "release" => release,
                       "started_at" => (@now - 3600 * 9).to_f,
                       "runtime" => { "ruby" => "3.4.2", "rails" => "8.1.3", "agent" => "0.1.0", "server" => "puma" } },
        "dropped" => {} }
    end

    def releases_for(spec)
      @releases ||= {}
      @releases[spec.slug] ||= begin
        rng = Random.new(spec.slug.sum)
        times = [ @from - 86_400 ]
        cursor = @from + rng.rand(6..30) * 3600
        while cursor < @now - 3 * 3600
          times << cursor
          cursor += rng.rand(14..52) * 3600
        end
        times.reject! { |time| time > @bad_deploy - 8 * 3600 } if spec.slug == "hook"
        times.concat([ @bad_deploy, @fix_deploy ]) if spec.slug == "hook"
        times.sort.map { |time| [ time, Digest::SHA1.hexdigest("#{spec.slug}#{time.to_i}")[0, 40] ] }
      end
    end

    private

    def say(message) = @output&.puts("demo: #{message}")

    def ensure_app(household, spec)
      App.unscoped.find_by(household_id: household.id, slug: spec.slug) ||
        App.create!(household: household, slug: spec.slug, name: spec.name)
    end

    def ensure_partitions
      day = @from.to_date - 1
      while day <= @now.to_date + 1
        Telemetry::Partitions.ensure!(today: day)
        day += 3
      end
    end

    def batch_for(app, spec, kind, release)
      header = Ingest::Batch::Header.new(kind: kind, host: "#{spec.slug}-#{kind}-1", pid: kind == "web" ? 7 : 1, release: release,
        started_at: nil, runtime: {}, dropped: {})
      Ingest::Batch.new(app: app, header: header, clock: Ingest::Clock.new(now: @now, max_past: 400.days))
    end

    # Writes a batch the way ingest does, without touching heartbeats
    # (history is not a process reporting now).
    def flush(app, batch)
      return if batch.accepted.zero?

      Ingest::Writer.write!(app, batch, heartbeat: false)
    end

    # The release deployed at a time: the last one at or before it (the
    # first, for a time before any). `releases` is [[time, sha]] in order.
    def release_at(releases, time)
      after = releases.bsearch_index { |at, _| at > time } || releases.size
      releases[[ after - 1, 0 ].max][1]
    end

    # Metric series written straight to the tables, as [name, kind, unit,
    # tags]: their ids, from the same dictionary ingest resolves through.
    def register_series(app, definitions)
      points = definitions.map do |name, kind, unit, tags|
        kind = Telemetry::MetricSeries::Kind.deserialize(kind) if kind.is_a?(String)
        Ingest::Records::Metric::Point.new(ts: @now, name: name, kind: kind, unit: unit,
          tags: tags, n: 0, sum: 0.0, min: nil, max: nil, last: nil, sketch: nil)
      end
      Ingest::SeriesResolver.resolve(app, points)
    end

    # Points written past the rollup: `raw` at full resolution, `folded`
    # into the 5-minute tier as the rollup would have left it.
    def write_points(raw: [], folded: [])
      raw.each_slice(5_000) { |slice| Telemetry::MetricPoint.insert_all!(slice, returning: false, record_timestamps: false) }
      folded.each_slice(5_000) { |slice| Telemetry::MetricPoint5m.insert_all(slice, returning: false, record_timestamps: false) }
    end

    # ---- shape of the day ------------------------------------------------

    # Traffic follows the household: quiet overnight, a morning bump, busy
    # in the evening. 0.08..1.0.
    def activity(time)
      hour = (time.getlocal.hour + time.min / 60.0)
      morning = Math.exp(-((hour - 8.0)**2) / 6.0)
      evening = Math.exp(-((hour - 20.0)**2) / 9.0)
      midday = 0.45 * Math.exp(-((hour - 13.0)**2) / 10.0)
      0.08 + 0.92 * [ morning * 0.7 + midday + evening, 1.0 ].min
    end

    def poisson(mean)
      return 0 if mean <= 0
      return (mean + @rng.rand * Math.sqrt(mean) * 2 - Math.sqrt(mean)).round.clamp(0, nil) if mean > 30

      limit = Math.exp(-mean)
      count = 0
      product = @rng.rand
      while product > limit
        count += 1
        product *= @rng.rand
      end
      count
    end

    def lognormal(median, sigma)
      u1 = [ @rng.rand, 1e-12 ].max
      normal = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * @rng.rand)
      median * Math.exp(sigma * normal)
    end

    def weighted(items, &weight)
      total = items.sum(&weight)
      pick = @rng.rand * total
      items.each do |item|
        pick -= weight.call(item)
        return item if pick <= 0
      end
      items.last
    end

    def hex(bytes) = @rng.bytes(bytes).unpack1("H*")

    # A v4-shaped uuid from the seeded generator, so a seed fills the same
    # instance every time.
    def uuid
      digits = hex(16)
      "#{digits[0, 8]}-#{digits[8, 4]}-4#{digits[13, 3]}-#{digits[16, 4]}-#{digits[20, 12]}"
    end

    def regressed?(spec, endpoint, time)
      spec.slug == "hook" && endpoint.name == "Api::V1::SearchController#index" && time >= @bad_deploy && time < @fix_deploy
    end

    def bursting?(spec, endpoint, time)
      spec.slug == "hub" && endpoint.name == "Api::V1::CalendarController#index" && @burst.cover?(time)
    end

    # ---- markers ---------------------------------------------------------

    def write_markers(app, spec, releases)
      batch = batch_for(app, spec, "web", nil)
      releases.drop(1).each do |time, sha|
        batch.add_record("t" => "marker", "ts" => time.to_f, "kind" => "deploy", "title" => "Deployed #{sha[0, 12]}",
          "attrs" => { "release" => sha })
      end
      if spec.slug == "hub"
        batch.add_record("t" => "marker", "ts" => @burst.begin.to_f, "kind" => "event",
          "title" => "Calendar provider returning 503s", "attrs" => { "provider" => "caldav" })
      end
      # The header's release is what a marker carries; set per marker.
      batch.markers.each { |row| row[:release] = row[:attrs]["release"] }
      flush(app, batch)
    end

    # ---- requests and jobs -----------------------------------------------

    def write_transactions(app, spec, releases)
      deployed = ->(time) { release_at(releases, time) }

      cursor = @from
      while cursor < @now
        upto = [ cursor + 6 * 3600, @now ].min
        batches = Hash.new { |hash, key| hash[key] = batch_for(app, spec, key[0], key[1]) }
        each_transaction(spec, cursor, upto, release_at: deployed) do |txn, spans, logs|
          kind = txn["kind"] == "job" ? "worker" : "web"
          kind = "web" unless spec.processes.key?(kind)
          batch = batches[[ kind, deployed.call(Time.at(txn["ts"])) ]]
          batch.add_record(txn)
          spans.each { |span| batch.add_record(span) }
          # A day of logs is plenty to look at, and a week would be most of
          # the database.
          logs.each { |log| batch.add_record(log) } if txn["ts"] > (@now - 86_400).to_f
        end
        batches.each_value { |batch| flush(app, batch) }
        cursor = upto
      end
    end

    # Yields (txn, spans, logs) wire records for every request and job of an
    # app in [from, to), minute by minute.
    def each_transaction(spec, from, to, release_at:)
      minute = Time.at(from.to_i - from.to_i % 60).utc
      while minute < to
        level = activity(minute)
        poisson(spec.rps * 60 * level).times do
          at = minute + @rng.rand * 60
          next if at < from || at >= to

          yield(*request(spec, weighted(spec.endpoints, &:share), at))
        end
        spec.jobs.each do |job|
          # Jobs run on a schedule, not on people: flatter than requests.
          poisson(job.per_hour / 60.0 * (0.6 + 0.4 * level)).times do
            at = minute + @rng.rand * 60
            next if at < from || at >= to

            yield(*job_run(spec, job, at))
          end
        end
        minute += 60
      end
    end

    def request(spec, endpoint, at)
      slow = regressed?(spec, endpoint, at)
      duration = lognormal(endpoint.median * (slow ? 2.4 : 1.0), endpoint.sigma)
      # The occasional stall: a GC pause, a cold cache, a lock.
      duration *= @rng.rand(4.0..12.0) if @rng.rand < 0.006
      error = @rng.rand < (bursting?(spec, endpoint, at) ? 0.34 : endpoint.error_rate)
      status = error ? [ 500, 500, 500, 502, 503 ].sample(random: @rng) : success_status(endpoint)
      status = 404 if !error && endpoint.route.include?(":id") && @rng.rand < 0.01

      db = duration * endpoint.db * @rng.rand(0.7..1.2) * (slow ? 0.5 : 1.0)
      ext = duration * endpoint.ext * @rng.rand(0.8..1.1)
      view = duration * endpoint.view * @rng.rand(0.7..1.3)
      db_n = endpoint.db_n.zero? ? 0 : [ (endpoint.db_n * @rng.rand(0.7..1.6)).round, 1 ].max
      db_n += @rng.rand(12..40) if endpoint.n1 && @rng.rand < 0.35
      trace = hex(16)
      span = hex(8)
      user = weighted(USERS) { |id| USERS.index(id).zero? ? 5 : 2 }
      path = endpoint.route.gsub(":id") { uuid }.sub("/*path", [ "/", "/wants", "/settings", "/search" ].sample(random: @rng))
      kept = error || duration > endpoint.median * 3.2 || @rng.rand < 0.1

      txn = {
        "t" => "txn", "ts" => at.to_f, "kind" => "request", "name" => endpoint.name, "trace" => trace, "span" => span,
        "dur" => duration.round(3), "status" => error ? "error" : "ok", "method" => endpoint.method, "route" => endpoint.route,
        "path" => path, "http" => status, "format" => endpoint.name.start_with?("Spa") ? "html" : "json",
        "db_ms" => db.round(3), "db_n" => db_n, "view_ms" => view.round(3), "ext_ms" => ext.round(3),
        "ext_n" => endpoint.ext.positive? ? @rng.rand(1..3) : 0, "cache_hit" => @rng.rand(0..4), "cache_miss" => @rng.rand(0..1),
        "gc_ms" => (@rng.rand < 0.2 ? @rng.rand(0.2..6.0) : 0).round(3), "alloc" => (duration * @rng.rand(300..900)).round,
        "n1" => endpoint.n1 && db_n > endpoint.db_n * 2, "user" => user, "visit" => "v_#{Digest::MD5.hexdigest("#{user}#{at.to_i / 1800}")[0, 12]}",
        "origin" => ORIGINS.sample(random: @rng), "kept" => kept, "attrs" => {}
      }
      txn["error"] = error_class(endpoint) if error
      txn.compact!
      [ txn, kept ? spans_for(txn, endpoint, at, db, db_n, view, ext) : [], logs_for(txn, spec, at) ]
    end

    def success_status(endpoint)
      case endpoint.method
      when "POST" then 201
      when "PATCH", "PUT" then 200
      else @rng.rand < 0.07 ? 304 : 200
      end
    end

    def error_class(endpoint)
      if endpoint.ext.positive?
        [ "UpstreamHttpClient::Error", "Net::ReadTimeout", "UpstreamHttpClient::RateLimitError" ].sample(random: @rng)
      else
        [ "ActiveRecord::StatementInvalid", "NoMethodError", "ActiveRecord::ConnectionTimeoutError" ].sample(random: @rng)
      end
    end

    def job_run(spec, job, at)
      duration = lognormal(job.median, job.sigma)
      error = @rng.rand < job.error_rate
      trace = hex(16)
      span = hex(8)
      db = duration * job.db * @rng.rand(0.7..1.2)
      kept = error || duration > job.median * 3 || @rng.rand < 0.1
      txn = {
        "t" => "txn", "ts" => at.to_f, "kind" => "job", "name" => job.name, "trace" => trace, "span" => span,
        "dur" => duration.round(3), "status" => error ? "error" : "ok", "queue" => job.queue,
        "queue_ms" => lognormal(180, 1.1).round(3), "attempt" => error ? @rng.rand(1..3) : 1,
        "db_ms" => db.round(3), "db_n" => @rng.rand(2..20), "ext_ms" => (duration * 0.5).round(3), "ext_n" => @rng.rand(0..4),
        "alloc" => (duration * @rng.rand(200..700)).round, "kept" => kept, "attrs" => {}
      }
      txn["error"] = [ "Net::ReadTimeout", "UpstreamHttpClient::Error", "ActiveRecord::Deadlocked" ].sample(random: @rng) if error
      endpoint = Fleet::Endpoint.new(name: job.name, db: job.db, ext: 0.4, view: 0.0, n1: false, db_n: 4)
      [ txn, kept ? spans_for(txn, endpoint, at, db, [ txn["db_n"], 8 ].min, 0.0, duration * 0.4) : [], logs_for(txn, spec, at) ]
    end

    SQL_SHAPES = [
      [ "Load", "SELECT \"%<t>s\".* FROM \"%<t>s\" WHERE \"%<t>s\".\"household_id\" = ? ORDER BY \"%<t>s\".\"created_at\" DESC LIMIT ?" ],
      [ "Load", "SELECT \"%<t>s\".* FROM \"%<t>s\" WHERE \"%<t>s\".\"id\" = ? LIMIT ?" ],
      [ "Count", "SELECT COUNT(*) FROM \"%<t>s\" WHERE \"%<t>s\".\"household_id\" = ?" ],
      [ "Exists?", "SELECT 1 AS one FROM \"%<t>s\" WHERE \"%<t>s\".\"status\" = ? LIMIT ?" ],
      [ "Update", "UPDATE \"%<t>s\" SET \"updated_at\" = ? WHERE \"%<t>s\".\"id\" = ?" ]
    ].freeze

    def spans_for(txn, endpoint, at, db, db_n, view, ext)
      spans = []
      table = endpoint.name[/(\w+?)s?Controller/, 1]&.underscore&.pluralize || endpoint.name.underscore.split("_").first.pluralize
      offset = txn["dur"] * 0.04
      shapes = Array.new([ db_n, 40 ].min) { SQL_SHAPES.sample(random: @rng) }
      # An N+1 is one statement shape, over and over.
      shapes = [ shapes.first ] + [ SQL_SHAPES[1] ] * (shapes.size - 1) if txn["n1"]
      shapes.each do |name, template|
        each_ms = db_n.zero? ? 0 : (db / db_n) * @rng.rand(0.4..1.8)
        spans << span(txn, at, offset, "sql", "#{table.classify} #{name}", format(template, t: table), each_ms)
        offset += each_ms * 1.15
      end
      if ext.positive?
        host = %w[api.example.com minio search bookorbit api.example.org immich].sample(random: @rng)
        spans << span(txn, at, offset, "http", "GET #{host}", "GET #{host}/api/v1/search", ext,
          status: txn["status"] == "error" && txn["error"].to_s.include?("Http") ? "error" : "ok")
        offset += ext
      end
      if view > 0.5
        spans << span(txn, at, offset, "view", "index.html", "public/index.html", view)
      end
      spans
    end

    def span(txn, at, offset_ms, kind, name, resource, duration, status: "ok")
      { "t" => "span", "ts" => at.to_f + offset_ms / 1000.0, "trace" => txn["trace"], "span" => hex(8), "parent" => txn["span"],
        "kind" => kind, "name" => name, "res" => resource, "dur" => duration.round(3), "status" => status, "attrs" => {} }
    end

    def logs_for(txn, _spec, at)
      logs = []
      if txn["kind"] == "request"
        logs << log(txn, at + txn["dur"] / 1000.0, "info",
          "Completed #{txn['http']} in #{txn['dur'].round}ms (ActiveRecord: #{txn['db_ms'].round(1)}ms | #{txn['db_n']} queries)")
      else
        logs << log(txn, at + txn["dur"] / 1000.0, "info", "Performed #{txn['name']} from SolidQueue(#{txn['queue']}) in #{txn['dur'].round}ms")
      end
      if txn["status"] == "error"
        logs << log(txn, at + txn["dur"] / 1000.0, "error", "#{txn['error']}: #{ERROR_MESSAGES.fetch(txn['error'], 'unexpected failure')}")
      elsif txn["n1"]
        logs << log(txn, at, "warn", "N+1 detected: #{txn['db_n']} queries in one request")
      elsif txn["dur"] > 1500 && txn["kind"] == "request"
        logs << log(txn, at, "warn", "Slow request: #{txn['name']} took #{txn['dur'].round}ms")
      end
      logs
    end

    ERROR_MESSAGES = {
      "Net::ReadTimeout" => "Net::ReadTimeout with #<TCPSocket:(closed)>",
      "UpstreamHttpClient::Error" => "upstream answered 503 Service Unavailable",
      "UpstreamHttpClient::RateLimitError" => "rate limited — retry after 60s",
      "ActiveRecord::StatementInvalid" => "PG::QueryCanceled: ERROR: canceling statement due to statement timeout",
      "ActiveRecord::ConnectionTimeoutError" => "could not obtain a connection from the pool within 5.000 seconds",
      "ActiveRecord::Deadlocked" => "PG::TRDeadlockDetected: ERROR: deadlock detected",
      "NoMethodError" => "undefined method 'title' for nil"
    }.freeze

    def log(txn, at, level, message)
      { "t" => "log", "ts" => at.to_f, "lvl" => level, "msg" => message, "src" => "rails", "trace" => txn["trace"], "span" => txn["span"],
        "attrs" => {} }
    end

    # ---- profiles --------------------------------------------------------

    # Windows of folded stacks: a minute each for the last two hours, five
    # minutes each before that (history only needs the shape).
    def write_profiles(app, spec, releases)
      spec.processes.each_key do |kind|
        transactions = kind == "worker" ? spec.jobs : spec.endpoints
        transactions = spec.endpoints + spec.jobs if spec.processes.size == 1
        prefix = kind == "worker" ? Fleet::JOB_PREFIX : Fleet::REQUEST_PREFIX

        cursor = [ @from, @now - 3 * 86_400 ].max
        batches = {}
        while cursor < @now
          width = cursor >= @now - 7200 ? 60 : 300
          release = release_at(releases, cursor)
          batch = (batches[release] ||= batch_for(app, spec, kind, release))
          record = profile_record(spec, transactions, prefix, cursor, width)
          batch.add_record(record) if record
          if batch.profiles.size >= 200
            flush(app, batch)
            batches.delete(release)
          end
          cursor += width
        end
        batches.each_value { |batch| flush(app, batch) }
      end
    end

    def profile_record(spec, transactions, prefix, at, width)
      hz = 100
      level = activity(at)
      funcs = []
      func_index = {}
      stacks = []
      stack_index = {}
      samples = []
      intern = lambda do |frames|
        ids = frames.map { |frame| func_index[frame] ||= (funcs << [ frame[0], frame[1], 0, frame[2] ]).size - 1 }
        stack_index[ids] ||= (stacks << ids).size - 1
      end

      transactions.each do |transaction|
        request = transaction.is_a?(Fleet::Endpoint)
        per_second = request ? spec.rps * transaction.share * level : transaction.per_hour / 3600.0
        busy_ms = per_second * width * transaction.median * 1.25
        next if busy_ms < 5

        slow = request && regressed?(spec, transaction, at)
        busy_ms *= 2.4 if slow
        own = request ? transaction.name.sub("#", "#") : "#{transaction.name}#perform"
        file = request ? "app/controllers/#{transaction.name.split('#').first.underscore}.rb" : "app/jobs/#{transaction.name.underscore}.rb"
        base = (request ? prefix : prefix) + [ [ own, file, "app" ] ]

        branches = transaction.stack.dup
        if slow
          # The regression: most of the extra time is in one function.
          merge = [ [ "Catalog::Kind#search", "app/services/catalog/kind.rb", "app" ], [ "Catalog::Kind#merge", "app/services/catalog/kind.rb", "app" ],
                    Fleet::REGRESSION ]
          branches = branches.map { |share, state, frames| [ share / 2.4, state, frames ] } + [ [ 1.4 / 2.4, "running", merge ] ]
        end
        branches.each do |share, state, frames|
          weight = (busy_ms * share / 1000.0 * hz * @rng.rand(0.85..1.15)).round
          next if weight <= 0

          samples << [ intern.call(base + frames), transaction.name, state, weight ]
        end
      end
      return nil if samples.empty?

      # The background: the agent's own thread, GC.
      samples << [ intern.call([ [ "Glass::Transport#work", "glass/lib/glass/transport.rb", "gem" ], [ "Zlib.gzip", "<cfunc>", "native" ] ]),
        nil, "running", [ (width * 0.02 * hz / 60).round, 1 ].max ]
      { "t" => "profile", "ts" => at.to_f, "dur" => width.to_f, "hz" => hz, "mode" => "wall", "funcs" => funcs, "stacks" => stacks,
        "samples" => samples }
    end

    # ---- metrics ---------------------------------------------------------

    # name, kind, unit, tags, value at a time
    def metric_series(spec, kind)
      seed = "#{spec.slug}#{kind}".sum
      wave = ->(time, period, amplitude) { Math.sin(time.to_f / period + seed) * amplitude }
      base = [
        [ "ruby.memory.rss_bytes", "gauge", "bytes", ->(t) { (210e6 + seed * 3e5) * (1 + 0.12 * activity(t)) + wave.call(t, 5400, 9e6) + sawtooth(t, 86_400 * 1.7, 60e6) } ],
        [ "ruby.heap.live_slots", "gauge", nil, ->(t) { 880_000 + 190_000 * activity(t) + wave.call(t, 900, 30_000) } ],
        [ "ruby.heap.free_slots", "gauge", nil, ->(t) { 120_000 + wave.call(t, 1300, 40_000).abs } ],
        [ "ruby.threads", "gauge", nil, ->(_) { kind == "web" ? 14 : 9 } ],
        [ "ruby.gc.count", "counter", nil, ->(t) { 0.4 + 2.2 * activity(t) } ],
        [ "ruby.gc.time_ms", "counter", "ms", ->(t) { 1.5 + 14 * activity(t) } ],
        [ "active_record.pool.busy", "gauge", nil, ->(t) { 1 + 3.5 * activity(t) + wave.call(t, 400, 0.8).abs } ],
        [ "active_record.pool.size", "gauge", nil, ->(_) { 14 } ],
        [ "fog.container.cpu_pct", "gauge", "percent", ->(t) { 1.5 + 22 * activity(t) * (spec.rps / 0.35) + wave.call(t, 240, 1.6).abs } ],
        [ "fog.container.memory_bytes", "gauge", "bytes", ->(t) { (250e6 + seed * 4e5) * (1 + 0.1 * activity(t)) + sawtooth(t, 86_400 * 1.7, 60e6) } ]
      ]
      if kind == "web"
        base += [
          [ "puma.busy_threads", "gauge", nil, ->(t) { [ 0.3 + 3.2 * activity(t) * (spec.rps / 0.2), 8 ].min } ],
          [ "puma.backlog", "gauge", nil, ->(t) { activity(t) > 0.92 ? 0.4 : 0.0 } ],
          [ "puma.pool_capacity", "gauge", nil, ->(t) { 8 - [ 0.3 + 3.2 * activity(t) * (spec.rps / 0.2), 8 ].min } ]
        ]
      else
        base += [
          [ "solid_queue.ready", "gauge", nil, ->(t) { (2.5 * activity(t) + wave.call(t, 700, 1.5)).abs } ],
          [ "solid_queue.failed", "gauge", nil, ->(_) { seed % 4 } ],
          [ "solid_queue.oldest_ready_age_s", "gauge", "s", ->(t) { (1.5 + 6 * activity(t) + wave.call(t, 1100, 2)).abs } ]
        ]
      end
      base.map { |name, type, unit, value| [ name, type, unit, { "process" => kind }, value ] }
    end

    def sawtooth(time, period, height) = (time.to_f % period) / period * height

    def metric_records(spec, from, to)
      records = []
      spec.processes.each_key do |kind|
        metric_series(spec, kind).each do |name, type, unit, tags, value|
          at = from.to_i - from.to_i % 10
          while at < to.to_i
            sample = [ value.call(Time.at(at)), 0 ].max * (type == "gauge" ? 1 : @rng.rand(0.7..1.3))
            records << { "t" => "metric", "ts" => at, "name" => name, "kind" => type, "unit" => unit, "tags" => tags,
                         "n" => 1, "sum" => sample, "min" => sample, "max" => sample, "last" => sample }.compact
            at += 10
          end
        end
      end
      records
    end

    def write_metrics(app, spec)
      raw_from = @now - RAW_METRIC_WINDOW
      # History, straight into the 5-minute tier.
      spec.processes.each_key do |kind|
        definitions = metric_series(spec, kind)
        ids = register_series(app, definitions.map { |name, type, unit, tags, _| [ name, type, unit, tags ] })
        rows = []
        definitions.zip(ids).each do |(_, type, _, _, value), id|
          at = @from.to_i - @from.to_i % 300
          while at < raw_from.to_i
            mid = [ value.call(Time.at(at + 150)), 0 ].max
            if type == "gauge"
              rows << { series_id: id, ts: Time.at(at).utc, n: 30, sum: mid * 30, min: mid * 0.96, max: mid * 1.05, last: mid }
            else
              total = mid * 30 * @rng.rand(0.9..1.1)
              rows << { series_id: id, ts: Time.at(at).utc, n: 30, sum: total, min: total / 40, max: total / 22, last: total / 30 }
            end
            at += 300
          end
        end
        write_points(folded: rows)
      end

      # The last two hours at full resolution, through the real builders.
      batch = batch_for(app, spec, "web", nil)
      metric_records(spec, raw_from, @now).each { |record| batch.add_record(record) }
      flush(app, batch)
    end

    # The rollup is told history is already folded up to where the raw
    # points begin, then run until it has caught up to the present.
    def finish_rollups
      raw_from = @now - RAW_METRIC_WINDOW
      Telemetry::Cursor.advance!("rollup:5m", Time.at(raw_from.to_i - raw_from.to_i % 300).utc)
      Telemetry::Cursor.where(name: "rollup:1h").delete_all
      40.times { break if Telemetry::Rollup.run!(now: @now).values.sum.zero? }
    end

    # ---- a third-party image ----------------------------------------------

    # An app as Fog::Sync would have made it: known by fog, never reporting.
    def ensure_image(household, image)
      app = App.unscoped.find_by(household_id: household.id, slug: image.slug) ||
        App.create!(household: household, slug: image.slug, name: image.name)
      app.update_columns(fog_name: image.slug,
        fog_state: { "rev" => 3, "healthy" => true, "state" => "running", "hosts" => [ "#{image.slug}.example.net" ] })
      app
    end

    # A downloader is idle for hours and then flat out: a few downloads a
    # day, each some minutes of network in, disk writes and CPU to unpack.
    def downloading?(time, seed)
      slot = time.to_i / 7200
      rng = Random.new(slot + seed)
      return false if rng.rand > 0.45

      start = rng.rand(0..4200)
      (time.to_i % 7200 - start).between?(0, rng.rand(600..2700))
    end

    # name, unit, value at a time — nil while the container is down, as fog
    # has no reading for a container that is not running.
    def container_series(image)
      seed = image.slug.sum
      busy = ->(t) { downloading?(t, seed) ? 1.0 : 0.0 }
      wave = ->(t, period, amplitude) { Math.sin(t.to_f / period + seed).abs * amplitude }
      running = ->(value) { ->(t) { @outage.cover?(t) ? nil : value.call(t) } }
      [
        [ "fog.container.up", nil, ->(t) { @outage.cover?(t) ? 0.0 : 1.0 } ],
        [ "fog.container.cpu_pct", "percent", running.call(->(t) { 0.6 + 36 * busy.call(t) + wave.call(t, 240, 1.2) }) ],
        [ "fog.container.memory_bytes", "bytes", running.call(->(t) { 180e6 + 140e6 * busy.call(t) + wave.call(t, 5400, 12e6) }) ],
        [ "fog.container.memory_limit_bytes", "bytes", running.call(->(_) { 2.0 * 1024**3 }) ],
        [ "fog.container.net_in_bps", "bytes", running.call(->(t) { 3e3 + 27e6 * busy.call(t) + wave.call(t, 180, 2e3 + 3e6 * busy.call(t)) }) ],
        [ "fog.container.net_out_bps", "bytes", running.call(->(t) { 2e3 + 5e5 * busy.call(t) + wave.call(t, 200, 1e3) }) ],
        [ "fog.container.disk_read_bps", "bytes", running.call(->(t) { 9e6 * busy.call(t) + wave.call(t, 900, 2e3) }) ],
        [ "fog.container.disk_write_bps", "bytes", running.call(->(t) { 25e6 * busy.call(t) + wave.call(t, 300, 4e3) }) ]
      ]
    end

    # What a week of Fog::Sync leaves behind: a reading a minute, kept raw
    # (a minute apart, a week is small) and folded into the 5-minute tier up
    # to where the rollup takes over, and the markers for the outage and an
    # image update.
    def write_container(app, image)
      definitions = container_series(image)
      tags = { "app" => image.slug, "source" => "fog" }
      ids = register_series(app, definitions.map { |name, unit, _| [ name, Telemetry::MetricSeries::Kind::Gauge, unit, tags ] })
      # Where finish_rollups tells the rollup to take over.
      folded_to = (@now - RAW_METRIC_WINDOW).to_i.then { |at| at - at % 300 }
      raw = []
      definitions.zip(ids).each do |(_, _, value), id|
        (@from.to_i - @from.to_i % 300...@now.to_i).step(60) do |at|
          reading = value.call(Time.at(at))
          raw << { series_id: id, ts: Time.at(at).utc, n: 1, sum: reading, min: reading, max: reading, last: reading, sketch: nil } if reading
        end
      end
      folded = raw.select { |row| row[:ts].to_i < folded_to }.group_by { |row| [ row[:series_id], row[:ts].to_i / 300 ] }.map do |(id, bucket), rows|
        values = rows.map { |row| row[:sum] }
        { series_id: id, ts: Time.at(bucket * 300).utc, n: values.size, sum: values.sum, min: values.min, max: values.max, last: values.last }
      end
      write_points(raw: raw, folded: folded)

      markers = [
        [ @now - 3 * 86_400, "deploy", "Deploy #3 succeeded by update", { "fog" => "deploy", "rev" => 3, "status" => "succeeded" } ],
        [ @outage.begin, "incident", "Health check failing", { "fog" => "health" } ],
        [ @outage.end, "event", "Healthy again", { "fog" => "health" } ]
      ].select { |marker| marker.first >= @from }
      rows = markers.map { |at, kind, title, attrs| { ts: at, app_id: app.telemetry_id, kind: kind, title: title, release: nil, source: "fog", attrs: attrs } }
      Telemetry::Marker.insert_all!(rows, returning: false, record_timestamps: false) if rows.any?
    end

    # ---- visitors --------------------------------------------------------

    PAGES = {
      "/" => "Home", "/wants" => "Wanted", "/wants/:id" => "Want", "/search" => "Search", "/settings" => "Settings",
      "/calendar" => "Calendar", "/authors" => "Authors"
    }.freeze
    ELEMENTS = [
      [ "Add want", "button", "main > form > button.primary" ], [ "Search", "button", "header > form > button" ],
      [ "Save", "button", "form > footer > button.primary" ], [ "Refresh", "button", "section > header > button" ],
      [ "Sign out", "button", "aside > div > button" ], [ "Wanted", "a", "nav > a" ], [ "Settings", "a", "nav > a" ]
    ].freeze
    BROWSERS = [ %w[Safari iOS phone 390x844], %w[Safari macOS desktop 1728x1117], %w[Chrome macOS desktop 1512x982], %w[Chrome Android phone 412x915],
                 %w[Safari iOS tablet 1024x1366], %w[Firefox Linux desktop 1920x1080] ].freeze
    REFERRERS = [ nil, nil, nil, "portal.example.net", "fog.example.net", "duckduckgo.com" ].freeze

    def write_visits(app, spec)
      batch = batch_for(app, spec, "web", nil)
      cursor = [ @from, @now - 3 * 86_400 ].max
      while cursor < @now
        level = activity(cursor)
        poisson(spec.rps * 40 * level).times do
          visit_records(spec, cursor + @rng.rand * 3600).each { |record| batch.add_record(record) }
        end
        if batch.pages.size > 4_000
          flush(app, batch)
          batch = batch_for(app, spec, "web", nil)
        end
        cursor += 3600
      end
      flush(app, batch)
    end

    # One visit: a few pages, a few clicks, vitals per page, sometimes an error.
    def visit_records(spec, at)
      user = weighted(USERS) { |id| USERS.index(id).zero? ? 5 : 2 }
      anonymous = @rng.rand < 0.15
      visitor = anonymous ? "a_#{Digest::MD5.hexdigest("#{spec.slug}#{at.to_i / 86_400}#{@rng.rand(3)}")[0, 16]}" : user
      visit = "v_#{Digest::MD5.hexdigest("#{spec.slug}#{at.to_f}#{@rng.rand}")[0, 12]}"
      browser, os, device, screen = BROWSERS.sample(random: @rng)
      ua = { "browser" => browser, "os" => os, "device" => device, "screen" => screen }
      origin = ORIGINS.sample(random: @rng)
      base = { "t" => "page", "visit" => visit, "visitor" => visitor, "user" => anonymous ? nil : user, "ua" => ua, "lang" => "en-US", "origin" => origin }
      records = []
      time = at
      pages = @rng.rand < 0.35 ? 1 : @rng.rand(2..6)
      route = [ "/", "/wants", "/search" ].sample(random: @rng)
      pages.times do |index|
        path = route.sub(":id", uuid)
        records << base.merge("ts" => time.to_f, "kind" => "pageview", "path" => path, "route" => route, "title" => "#{spec.name} · #{PAGES[route]}",
          "ref" => index.zero? ? REFERRERS.sample(random: @rng)&.then { |host| "https://#{host}/" } : nil)
        dwell = lognormal(25, 1.0)
        @rng.rand(0..3).times do
          name, tag, sel = ELEMENTS.sample(random: @rng)
          records << base.merge("ts" => (time + @rng.rand * dwell).to_f, "kind" => tag == "a" ? "click" : "click", "path" => path, "route" => route,
            "name" => name, "el" => { "tag" => tag, "role" => tag == "a" ? "link" : "button", "sel" => sel, "href" => tag == "a" ? "/#{name.downcase}" : nil },
            "props" => @rng.rand < 0.04 ? { "rage" => true } : {})
        end
        if @rng.rand < 0.02
          records << base.merge("ts" => (time + dwell * 0.5).to_f, "kind" => "error", "path" => path, "route" => route, "name" => "TypeError",
            "props" => { "file" => "/assets/index.js", "line" => 1 })
        end
        slow = device == "phone" ? 1.6 : 1.0
        records << base.merge("ts" => (time + dwell).to_f, "kind" => "vital", "path" => path, "route" => route,
          "vitals" => { "lcp" => lognormal(1400 * slow, 0.4).round, "inp" => lognormal(90 * slow, 0.6).round, "cls" => (@rng.rand * 0.08).round(3),
                        "ttfb" => lognormal(80, 0.4).round, "fcp" => lognormal(600 * slow, 0.35).round })
        time += dwell
        route = PAGES.keys.sample(random: @rng)
      end
      records
    end

    # ---- processes -------------------------------------------------------

    def write_processes(app, spec, releases)
      release = releases.last[1]
      spec.processes.each_key do |kind|
        header = Ingest::Batch::Header.new(kind: kind, host: "#{spec.slug}-#{kind}-1", pid: kind == "web" ? 7 : 1, release: release,
          started_at: releases.last[0] + 40, runtime: { "ruby" => "3.4.2", "rails" => "8.1.3", "agent" => "0.1.0", "server" => "puma" },
          dropped: {})
        Telemetry::AgentProcess.where(app_id: app.telemetry_id, host: header.host).delete_all
        Ingest::Heartbeat.beat!(app, header, records: 0, now: Time.now.utc)
      end
      app.update_columns(first_seen_at: @from, last_seen_at: Time.current)
    end
  end
end
