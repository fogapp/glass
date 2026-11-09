# typed: strict
# frozen_string_literal: true

module Triage
  # The moments an app's endpoints were slow together: several of them, each
  # well past its own habit, within the same couple of seconds. What slows
  # unrelated code at the same instant is not in that code, so an endpoint
  # whose slow requests are mostly these moments did not regress.
  #
  # Moments alone are not a finding — a page that asks for a dozen things at
  # once makes them all the time. They are one when the profiler names what
  # the endpoints share: opening database connections, which a quiet
  # stretch makes them do again (the pool closes what sits idle). Then Stall
  # reports the moments as one finding, and Regression leaves the endpoints
  # they explain to it.
  class Stalls
    extend T::Sig

    Row = T.type_alias { Scan::Row }

    # Slow requests closer together than this are one moment.
    MOMENT_S = 2.0
    # How many endpoints must be slow at once for a moment to be the app's,
    # not one endpoint's.
    MIN_ENDPOINTS = 3
    # A request is slow against its endpoint's habit when it takes this many
    # times its median before…
    TIMES = 3.0
    # …and this long at least: a 4 ms call taking 15 ms is not slow.
    MIN_SLOW_MS = 100.0
    # An endpoint is left to the moments when at least this share of its
    # slow requests fell in them.
    EXPLAINED = 0.5
    # The slowest requests of an app that are read for moments.
    SLOWEST = 300
    # It takes this many moments to be a habit rather than a hiccup.
    MIN_MOMENTS = 2
    # The functions that open a database connection, or prepare a
    # statement on one that is new.
    CONNECTING = T.let(
      /\A(?:PG::Connection[#.](?:connect_poll|connect_start|async_connect|prepare)|Mysql2::Client#connect|Trilogy#initialize)\z/,
      Regexp
    )
    # Opening connections is what the endpoints share when it holds this
    # much of their profiled time, and half again what it held before.
    MIN_CONNECTING = 0.1
    CONNECTING_GROWTH = 1.5

    # One moment: the slow requests in it, slowest first.
    class Moment < T::Struct
      extend T::Sig

      const :rows, T::Array[Row]

      sig { returns(Float) }
      def at = rows.map { |row| row["ts"].to_f }.min.to_f

      sig { returns(T::Array[String]) }
      def names = rows.map { |row| row["name"].to_s }.uniq
    end

    # An app's moments, the endpoints they explain (or every endpoint in
    # them, when none is mostly theirs), the time they cost — each slow
    # request's excess over its endpoint's habit — and the share of those
    # endpoints' profiled time spent opening connections, now and before.
    class App < T::Struct
      const :app, String
      const :moments, T::Array[Moment]
      const :explained, T::Array[String]
      const :names, T::Array[String]
      const :excess_ms, Float
      const :connecting, Float
      const :connecting_before, Float
    end

    sig { params(scan: Scan).void }
    def initialize(scan)
      @scan = scan
    end

    # Every app whose endpoints stalled together on opening connections,
    # by slug.
    sig { returns(T::Hash[String, App]) }
    def apps
      @apps ||= T.let(read, T.nilable(T::Hash[String, App]))
    end

    # Whether an endpoint's slow requests are mostly the app's moments.
    sig { params(app: T.untyped, name: String).returns(T::Boolean) }
    def explains?(app, name) = apps[app.to_s]&.explained&.include?(name) || false

    private

    sig { returns(Scan) }
    attr_reader :scan

    sig { returns(T::Hash[String, App]) }
    def read
      now = scan.work
      habit = scan.work(baseline: true)
      slugs = now.keys.select { |(_, kind, _)| kind == "request" }.map(&:first).uniq.compact
      slugs.filter_map do |slug|
        slowest = scan.list(source: "transactions", filter: "app:#{slug} kind:request", limit: SLOWEST, order: "-duration")
        usual = ->(row) { (habit[[ slug, "request", row["name"] ]] || now[[ slug, "request", row["name"] ]] || {})["p50(duration)"].to_f }
        slow = slowest.select { |row| row["duration"].to_f >= [ MIN_SLOW_MS, TIMES * usual.call(row) ].max }
        moments = together(slow)
        next if moments.size < MIN_MOMENTS

        inside = moments.flat_map(&:rows).to_set(&:object_id)
        explained = slow.group_by { |row| row["name"].to_s }.select do |_, rows|
          rows.count { |row| inside.include?(row.object_id) } >= EXPLAINED * rows.size
        end.keys
        names = explained.presence || moments.flat_map(&:names).uniq
        share, share_before = connecting(slug, names)
        next if share < MIN_CONNECTING || share < share_before * CONNECTING_GROWTH

        excess = moments.flat_map(&:rows).sum { |row| row["duration"].to_f - usual.call(row) }
        [ slug, App.new(app: slug, moments: moments, explained: explained, names: names, excess_ms: excess, connecting: share,
          connecting_before: share_before) ]
      end.to_h
    end

    # The share of the endpoints' profiled time spent opening connections,
    # over the range and over the window before.
    sig { params(app: String, names: T::Array[String]).returns([ Float, Float ]) }
    def connecting(app, names)
      filter = "app:#{app} #{Query::Filter.quote_any('transaction', names)}"
      window = scan.window
      now, before = [ [ window.from, window.to ], [ window.baseline_from, window.baseline_to ] ].map do |from, to|
        scan.top_functions(from, to, filter).select { |row| CONNECTING.match?(row[:name].to_s) }.sum { |row| row[:self_share].to_f }
      end
      [ now.to_f, before.to_f ]
    end

    # The slow requests grouped by time, kept where enough endpoints share
    # the moment.
    sig { params(rows: T::Array[Row]).returns(T::Array[Moment]) }
    def together(rows)
      groups = rows.sort_by { |row| row["ts"].to_f }.slice_when { |a, b| b["ts"].to_f - a["ts"].to_f > MOMENT_S }
      groups.filter_map do |group|
        moment = Moment.new(rows: group.sort_by { |row| -row["duration"].to_f })
        moment if moment.names.size >= MIN_ENDPOINTS
      end
    end
  end
end
