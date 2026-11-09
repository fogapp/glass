# typed: strict
# frozen_string_literal: true

module Triage
  # One pass of Triage: who is asking, over what range, about which app —
  # and, when one finding is being worked up, about which subject. Detectors
  # ask through it, so the same table is read once however many detectors
  # want it.
  class Scan
    extend T::Sig

    Row = T.type_alias { T::Hash[String, T.untyped] }

    sig { returns(Household) }
    attr_reader :household

    sig { returns(Query::Context) }
    attr_reader :context

    sig { returns(Window) }
    attr_reader :window

    sig { returns(T.nilable(String)) }
    attr_reader :app

    sig { returns(T.nilable(Subject)) }
    attr_reader :subject

    sig do
      params(household: Household, window: Window, app: T.nilable(String), subject: T.nilable(Subject),
        context: T.nilable(Query::Context)).void
    end
    def initialize(household:, window:, app: nil, subject: nil, context: nil)
      @household = household
      @context = T.let(context || Query::Context.new(household), Query::Context)
      @window = window
      @app = T.let(app.presence&.downcase, T.nilable(String))
      @subject = subject
      @answers = T.let({}, T::Hash[String, T::Array[Row]])
      @functions = T.let({}, T::Hash[[ Float, Float, String ], T::Array[T::Hash[Symbol, T.untyped]]])
      @stalls = T.let(nil, T.nilable(Stalls))
    end

    # The moments the apps stalled, worked out once a pass: Stall reports
    # them and Regression leaves the endpoints they explain alone.
    sig { returns(Stalls) }
    def stalls = @stalls ||= Stalls.new(self)

    # The terms, scoped to the app asked about.
    sig { params(terms: T.nilable(String)).returns(String) }
    def filter(*terms) = [ app && Query::Filter.pair("app", app), *terms ].filter_map { |term| term.to_s.strip.presence }.join(" ")

    # A table answer's rows. Memoised by the question, so detectors that
    # share a reading share a statement. `between` reads a stretch of its
    # own instead of the range or the baseline: the last minutes of it, or
    # since something happened.
    sig do
      params(source: String, group_by: T::Array[String], compute: T::Array[String], filter: String, baseline: T::Boolean,
        order: T.nilable(String), limit: Integer, between: T.nilable([ Time, Time ])).returns(T::Array[Row])
    end
    def table(source:, group_by:, compute:, filter:, baseline: false, order: nil, limit: Query::Request::MAX_LIMIT, between: nil)
      params = request_params(source: source, shape: "table", baseline: baseline, filter: filter, between: between).merge(
        "group_by" => group_by, "compute" => compute, "order" => order, "limit" => limit
      ).compact
      rows(params)
    end

    # The baseline's rows for the groups a reading of the range found, and
    # only those. Read whole, the baseline is cut at the limit like any
    # table, and a group it ranked low would look as if it never happened
    # before. The groups are narrowed by their last field; a batch that
    # comes back full is halved until none does.
    sig do
      params(source: String, group_by: T::Array[String], compute: T::Array[String], filter: String, found: T::Array[Row])
        .returns(T::Array[Row])
    end
    def baseline(source:, group_by:, compute:, filter:, found:)
      field = T.must(group_by.last)
      values = found.filter_map { |row| row[field] }.uniq
      baseline_of(values) do |batch|
        table(source: source, group_by: group_by, compute: compute, filter: [ filter, Query::Filter.quote_any(field, batch) ].join(" ").strip,
          baseline: true)
      end
    end

    # A list answer's rows: newest first, or ranked by `order`. Memoised
    # like a table.
    sig { params(source: String, filter: String, limit: Integer, order: T.nilable(String)).returns(T::Array[Row]) }
    def list(source:, filter:, limit:, order: nil)
      params = request_params(source: source, shape: "list", baseline: false, filter: filter)
        .merge("limit" => limit, "order" => order).compact
      rows(params)
    end

    # The functions the profiler saw the most self time in, for a filter
    # over profile samples and a stretch of time. Memoised like a table.
    sig { params(from: Time, to: Time, filter: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def top_functions(from, to, filter)
      @functions[[ from.to_f, to.to_f, filter ]] ||= begin
        range = Profiles::Flamegraph::Range.new(from: from, to: to, filter: filter)
        Profiles::TopFunctions.rank(Profiles::Flamegraph.new(context: context, range: range).build, limit: 10)
      end
    end

    # The question behind a chart, for the console to ask: the baseline and
    # the range together, so the change is in the picture.
    sig { params(source: String, filter: String, compute: T::Array[String], group_by: T::Array[String]).returns(Row) }
    def chart(source:, filter:, compute:, group_by: [])
      { "source" => source, "shape" => "timeseries", "from" => window.baseline_from.to_f, "to" => window.to.to_f,
        "filter" => filter, "compute" => compute, "group_by" => group_by.presence }.compact
    end

    # Every unit of work in range by app, kind and name, with the figures
    # the work detectors read. `narrow` is a detail's subject; a scan of the
    # fleet passes nothing.
    WORK_COMPUTES = T.let([
      "count", "errors", "error_rate", "sum(duration)", "p50(duration)", "p95(duration)", "avg(duration)", "avg(db)",
      "avg(db_count)", "avg(view)", "avg(ext)", "avg(gc)", "avg(app_time)", "p95(queue_ms)"
    ].freeze, T::Array[String])

    sig { params(narrow: T.nilable(String), baseline: T::Boolean).returns(T::Hash[T::Array[T.untyped], Row]) }
    def work(narrow: nil, baseline: false)
      group_by = %w[app kind name]
      rows = table(source: "transactions", group_by: group_by, compute: WORK_COMPUTES, filter: filter(narrow))
      rows = self.baseline(source: "transactions", group_by: group_by, compute: WORK_COMPUTES, filter: filter(narrow), found: rows) if baseline
      keyed(rows, group_by)
    end

    # Rows by the values of `keys`, in that order: a table's groups, to
    # look up the same group in another reading.
    sig { params(rows: T::Array[Row], keys: T::Array[String]).returns(T::Hash[T::Array[T.untyped], Row]) }
    def keyed(rows, keys) = rows.to_h { |row| [ keys.map { |key| row[key] }, row ] }

    # Whether the range's reading of work holds every unit of work in it,
    # rather than the busiest that fit under the limit.
    sig { params(narrow: T.nilable(String)).returns(T::Boolean) }
    def work_complete?(narrow: nil) = work(narrow: narrow).size < Query::Request::MAX_LIMIT

    sig { params(params: Row).returns(T::Array[Row]) }
    def rows(params)
      @answers[JSON.generate(params)] ||= Query::Runner.run(Query::Request.from_params(params), context).fetch(:rows)
    end
    private :rows

    sig do
      params(values: T::Array[T.untyped], read: T.proc.params(batch: T::Array[T.untyped]).returns(T::Array[Row]))
        .returns(T::Array[Row])
    end
    def baseline_of(values, &read)
      return [] if values.empty?

      rows = read.call(values)
      return rows if rows.size < Query::Request::MAX_LIMIT || values.size == 1

      values.each_slice((values.size + 1) / 2).flat_map { |batch| baseline_of(batch, &read) }
    end
    private :baseline_of

    sig { params(source: String, shape: String, baseline: T::Boolean, filter: String, between: T.nilable([ Time, Time ])).returns(Row) }
    def request_params(source:, shape:, baseline:, filter:, between: nil)
      from, to = between || (baseline ? [ window.baseline_from, window.baseline_to ] : [ window.from, window.to ])
      { "source" => source, "shape" => shape, "from" => from.to_f, "to" => to.to_f, "filter" => filter }
    end
    private :request_params
  end
end
