# typed: strict
# frozen_string_literal: true

module Query
  # The `metrics` source: a named metric's series, read from whichever
  # rollup tier suits the range, folded across series into the groups asked
  # for.
  #
  #   { source: "metrics", metric: "rails.request.duration",
  #     compute: ["p95"], group_by: ["controller"], filter: "app:hook" }
  #
  # Filters and group-bys name tags (and `app`). What a function means
  # depends on the metric's kind:
  #
  #   counter  sum (default), rate, count
  #   gauge    avg (default), min, max, last, sum — `sum` and `last` add the
  #            series together (total memory across processes), `avg` is
  #            the mean of every sample
  #   dist     avg, p50…p99 (default p95), min, max, sum, count, rate
  #   set      count (default)
  #
  # Percentiles are taken from merged sketches (Telemetry::Sketch), never
  # averaged.
  class Metrics
    extend T::Sig

    Kind = Telemetry::MetricSeries::Kind

    MAX_SERIES = 5_000
    FUNCTIONS = T.let((%w[sum avg min max last count rate] + Compute::PERCENTILES.keys).freeze, T::Array[String])
    DEFAULTS = T.let({ Kind::Counter => "sum", Kind::Gauge => "avg", Kind::Dist => "p95", Kind::Set => "count" }.freeze,
      T::Hash[Kind, String])

    # A tier of metric points: its table, its resolution, and how far back
    # it is kept by default (the planner prefers the finest tier that still
    # covers the range).
    class Tier < T::Struct
      const :table, String
      const :width, Integer
      # The rollup checkpoint that says how far this tier has been filled
      # (Telemetry::Rollup); nil for the raw tier, which is always current.
      const :cursor, T.nilable(String), default: nil
    end

    TIERS = T.let([
      Tier.new(table: "metric_points", width: 10),
      Tier.new(table: "metric_points_5m", width: 300, cursor: "rollup:5m"),
      Tier.new(table: "metric_points_1h", width: 3_600, cursor: "rollup:1h")
    ].freeze, T::Array[Tier])

    # A stretch of the range and the tier it is read from.
    class Segment < T::Struct
      const :table, String
      const :from, Time
      const :to, Time
    end

    # One series' summary for one bucket, as read from a tier.
    class Cell < T::Struct
      prop :n, Float, default: 0.0
      prop :sum, Float, default: 0.0
      prop :min, T.nilable(Float), default: nil
      prop :max, T.nilable(Float), default: nil
      prop :last, T.nilable(Float), default: nil
    end

    # What one group holds for one bucket, folded across its series.
    class Fold < T::Struct
      extend T::Sig

      prop :n, Float, default: 0.0
      prop :sum, Float, default: 0.0
      prop :min, T.nilable(Float), default: nil
      prop :max, T.nilable(Float), default: nil
      # Σ of each series' mean, and Σ of each series' last value: how gauges
      # add across series.
      prop :sum_of_means, Float, default: 0.0
      prop :sum_of_lasts, Float, default: 0.0
      prop :series, Integer, default: 0
      prop :sketch, T.nilable(Telemetry::Sketch), default: nil

      sig { params(cell: Cell).void }
      def add(cell)
        self.n += cell.n
        self.sum += cell.sum
        low = cell.min
        high = cell.max
        self.min = [ min, low ].compact.min if low
        self.max = [ max, high ].compact.max if high
        self.sum_of_means += cell.sum / cell.n if cell.n.positive?
        self.sum_of_lasts += cell.last.to_f
        self.series += 1
      end
    end

    sig { params(request: Request, context: Context).void }
    def initialize(request, context)
      @request = request
      @context = context
      @metric = T.let(request.metric || raise(Invalid, "A metrics query needs a metric name"), String)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def run
      series = matching_series
      kind = series.first&.fetch(:kind) || Kind::Gauge
      computes = resolve_computes(kind)
      groups = group_series(series)

      case @request.shape
      when Request::Shape::Timeseries then timeseries(series, groups, computes, kind)
      when Request::Shape::Table then table(series, groups, computes, kind)
      else raise Invalid, "Metrics can be drawn as a timeseries or a table, not as a #{@request.shape.serialize}"
      end
    end

    private

    # ---- series ----------------------------------------------------------

    # The series this query reads: the metric's, in the asker's apps,
    # matching the tag filters.
    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def matching_series
      statement = Statement.new
      where = MetricWhere.new(context: @context, statement: statement).sql(metric: @metric, filter: @request.filter)
      return [] if where.nil?

      sql = "SELECT id, app_id, kind, unit, tags FROM metric_series WHERE #{where} LIMIT #{MAX_SERIES + 1}"
      rows = Runner.select(statement.to_sql(sql))
      raise Invalid, "“#{@metric}” has more than #{MAX_SERIES} matching series — add a filter" if rows.size > MAX_SERIES

      rows.map do |row|
        tags = row["tags"]
        { id: row["id"].to_i, app_id: row["app_id"].to_i, kind: Kind.deserialize(row["kind"]), unit: row["unit"],
          tags: tags.is_a?(String) ? JSON.parse(tags) : (tags || {}) }
      end
    end

    # Series ids by group value, in the order groups were first seen.
    sig { params(series: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Hash[T::Array[T.untyped], T::Array[Integer]]) }
    def group_series(series)
      series.each_with_object({}) do |row, out|
        key = @request.group_by.map { |name| name == "app" ? @context.slug(row[:app_id]) : row[:tags][name] }
        (out[key] ||= []) << row[:id]
      end
    end

    sig { params(kind: Kind).returns(T::Array[Compute]) }
    def resolve_computes(kind)
      computes = @request.computes.presence || [ Compute.parse(DEFAULTS.fetch(kind)) ]
      computes.each do |compute|
        next if FUNCTIONS.include?(compute.fn)

        raise Invalid, "Metrics take #{FUNCTIONS.join(', ')} — not “#{compute.key}”"
      end
      if kind != Kind::Dist && computes.any? { |compute| Compute::PERCENTILES.key?(compute.fn) }
        raise Invalid, "“#{@metric}” is a #{kind.serialize}, not a distribution — it has no percentiles"
      end
      computes
    end

    # ---- shapes ----------------------------------------------------------

    sig do
      params(series: T::Array[T::Hash[Symbol, T.untyped]], groups: T::Hash[T::Array[T.untyped], T::Array[Integer]],
        computes: T::Array[Compute], kind: Kind).returns(T::Hash[Symbol, T.untyped])
    end
    def timeseries(series, groups, computes, kind)
      tier, step = plan
      times = Step.times(from: @request.from, to: @request.to, step: step)
      folds = fold(series, groups, tier, step, sketches: needs_sketch?(computes))
      unit = series.first&.fetch(:unit)

      ranked = rank(groups.keys, computes, kind, folds).first(@request.limit)
      answer = ranked.flat_map do |group|
        computes.map do |compute|
          values = times.map { |time| value(compute, kind, folds.dig(group, time), seconds: step.to_f) }
          { key: compute.key, group: @request.group_by.zip(group).to_h, unit: unit_for(compute, unit), values: values }
        end
      end
      { shape: "timeseries", from: @request.from.to_f, to: @request.to.to_f, step: step, times: times,
        series: answer, metric: @metric, kind: kind.serialize }
    end

    sig do
      params(series: T::Array[T::Hash[Symbol, T.untyped]], groups: T::Hash[T::Array[T.untyped], T::Array[Integer]],
        computes: T::Array[Compute], kind: Kind).returns(T::Hash[Symbol, T.untyped])
    end
    def table(series, groups, computes, kind)
      tier, = plan
      whole = @request.seconds.ceil
      folds = fold(series, groups, tier, nil, sketches: needs_sketch?(computes))
      unit = series.first&.fetch(:unit)

      rows = groups.keys.map do |group|
        row = @request.group_by.zip(group).to_h
        computes.each { |compute| row[compute.key] = value(compute, kind, folds.dig(group, 0), seconds: whole.to_f) }
        row
      end
      first = T.must(computes.first).key
      rows = rows.sort_by { |row| -(row[first] || -Float::INFINITY).to_f }.first(@request.limit)

      columns = @request.group_by.map { |name| { key: name, label: name, kind: "dimension" } } +
        computes.map { |compute| { key: compute.key, label: compute.key, kind: "measure", unit: unit_for(compute, unit) } }
      { shape: "table", from: @request.from.to_f, to: @request.to.to_f, columns: columns, rows: rows,
        metric: @metric, kind: kind.serialize }
    end

    # Groups ordered by the first compute over the whole range, largest
    # first: the top-N a chart should draw. A gauge is ranked by its level
    # (the sum of its series' means, as `sum` reads it), never by its raw
    # sample total — a series sampled every second would otherwise outrank
    # a larger one sampled every minute.
    sig do
      params(keys: T::Array[T::Array[T.untyped]], computes: T::Array[Compute], kind: Kind,
        folds: T::Hash[T::Array[T.untyped], T::Hash[Integer, Fold]]).returns(T::Array[T::Array[T.untyped]])
    end
    def rank(keys, computes, kind, folds)
      return keys if keys.size <= 1

      first = T.must(computes.first)
      keys.sort_by do |group|
        total = Fold.new
        (folds[group] || {}).each_value do |bucket|
          total.n += bucket.n
          total.sum += bucket.sum
          total.sum_of_means += bucket.sum_of_means
          total.max = [ total.max, bucket.max ].compact.max
        end
        magnitude =
          if total.max && first.fn == "max" then total.max.to_f
          elsif kind == Kind::Gauge then total.sum_of_means.abs
          else total.sum.abs + total.n
          end
        -magnitude
      end
    end

    # ---- reading ---------------------------------------------------------

    # The tier and the bucket width: of the tiers that still hold `from`,
    # the coarsest that is at least as fine as the step — an hourly chart
    # over a week reads 168 rows a series, not 60,480.
    sig { returns([ Tier, Integer ]) }
    def plan
      step = Step.for(from: @request.from, to: @request.to, requested: @request.step)
      setting = AppSetting.cached
      age_days = (Time.now.utc - @request.from) / 86_400.0
      # A quarter day of margin: the oldest day is dropped at a UTC boundary.
      holding = TIERS.select { |tier| age_days <= setting.retention_for(Telemetry::Tables.fetch(tier.table)) - 0.25 }
      holding = [ T.must(TIERS.last) ] if holding.empty?
      chosen = holding.select { |tier| tier.width <= step }.last || T.must(holding.first)
      [ chosen, [ step, chosen.width ].max ]
    end

    # A rolled-up tier ends at its checkpoint — minutes behind the clock for
    # 5m, up to an hour for 1h. The rest of the range is read from the next
    # finer tier, down to the raw points, so the newest bucket of a week
    # chart is as current as the newest bucket of a ten-minute one.
    sig { params(chosen: Tier).returns(T::Array[Segment]) }
    def segments(chosen)
      start = T.let(@request.from, Time)
      T.must(TIERS.index(chosen)).downto(0).filter_map do |index|
        tier = T.must(TIERS[index])
        cursor = tier.cursor
        filled = cursor ? (Telemetry::Cursor.position(cursor)&.utc || start) : @request.to
        upto = [ filled, @request.to ].min
        next if upto <= start

        segment = Segment.new(table: tier.table, from: start, to: upto)
        start = upto
        segment
      end
    end

    sig { params(computes: T::Array[Compute]).returns(T::Boolean) }
    def needs_sketch?(computes) = computes.any? { |compute| Compute::PERCENTILES.key?(compute.fn) }

    # group → bucket start → Fold. `step` nil folds the whole range into
    # bucket 0.
    sig do
      params(series: T::Array[T::Hash[Symbol, T.untyped]], groups: T::Hash[T::Array[T.untyped], T::Array[Integer]],
        tier: Tier, step: T.nilable(Integer), sketches: T::Boolean)
        .returns(T::Hash[T::Array[T.untyped], T::Hash[Integer, Fold]])
    end
    def fold(series, groups, tier, step, sketches:)
      folds = T.let({}, T::Hash[T::Array[T.untyped], T::Hash[Integer, Fold]])
      return folds if series.empty?

      group_of = groups.each_with_object({}) { |(group, ids), out| ids.each { |id| out[id] = group } }
      ids = series.map { |row| row[:id] }
      bucket = step ? "extract(epoch FROM date_bin('#{step} seconds', ts, TIMESTAMPTZ 'epoch'))::bigint" : "0"

      # A bucket can straddle two segments (a 15-minute bucket, a 5-minute
      # checkpoint), so each series' bucket is assembled first and only then
      # folded into its group — otherwise a gauge read from two tiers would
      # count as two series.
      parts = segments(tier)
      cells = T.let({}, T::Hash[[ Integer, Integer ], Cell])
      parts.each do |segment|
        summary_rows(segment, ids, bucket).each do |row|
          cell = (cells[[ row["series_id"].to_i, row["bucket"].to_i ]] ||= Cell.new)
          cell.n += row["n"].to_f
          cell.sum += row["sum"].to_f
          cell.min = [ cell.min, row["min"]&.to_f ].compact.min
          cell.max = [ cell.max, row["max"]&.to_f ].compact.max
          # Segments run oldest to newest, so the later one's `last` wins.
          cell.last = row["last"].to_f unless row["last"].nil?
        end
      end
      cells.each do |(series_id, at), cell|
        ((folds[group_of[series_id]] ||= {})[at] ||= Fold.new).add(cell)
      end
      return folds unless sketches

      parts.flat_map { |segment| sketch_rows(segment, ids, bucket) }.each do |row|
        target = ((folds[group_of[row["series_id"].to_i]] ||= {})[row["bucket"].to_i] ||= Fold.new)
        (target.sketch ||= Telemetry::Sketch.new).add_bucket(row["idx"].to_i, row["cnt"].to_i)
      end
      folds
    end

    sig { params(segment: Segment, ids: T::Array[Integer], bucket: String).returns(T::Array[Runner::Row]) }
    def summary_rows(segment, ids, bucket)
      statement = Statement.new
      sql = "SELECT series_id, #{bucket} AS bucket, sum(n) AS n, sum(sum) AS sum, min(min) AS min, max(max) AS max, " \
            "(array_agg(last ORDER BY ts DESC) FILTER (WHERE last IS NOT NULL))[1] AS last " \
            "FROM #{segment.table} WHERE series_id IN (#{statement.bind(ids)}) " \
            "AND ts >= #{statement.bind(segment.from)} AND ts < #{statement.bind(segment.to)} GROUP BY 1, 2"
      Runner.select(statement.to_sql(sql))
    end

    sig { params(segment: Segment, ids: T::Array[Integer], bucket: String).returns(T::Array[Runner::Row]) }
    def sketch_rows(segment, ids, bucket)
      statement = Statement.new
      sql = "SELECT series_id, #{bucket} AS bucket, sketch[2 * g - 1] AS idx, sum(sketch[2 * g]) AS cnt " \
            "FROM #{segment.table} CROSS JOIN LATERAL generate_series(1, cardinality(sketch) / 2) AS g " \
            "WHERE series_id IN (#{statement.bind(ids)}) AND sketch IS NOT NULL " \
            "AND ts >= #{statement.bind(segment.from)} AND ts < #{statement.bind(segment.to)} GROUP BY 1, 2, 3"
      Runner.select(statement.to_sql(sql))
    end

    # ---- values ----------------------------------------------------------

    sig { params(compute: Compute, kind: Kind, fold: T.nilable(Fold), seconds: Float).returns(T.nilable(Float)) }
    def value(compute, kind, fold, seconds:)
      if fold.nil? || fold.series.zero?
        return kind == Kind::Counter && %w[sum rate count].include?(compute.fn) ? 0.0 : nil
      end

      gauge = kind == Kind::Gauge
      case compute.fn
      when "sum" then gauge ? fold.sum_of_means : fold.sum
      when "rate" then (gauge || kind == Kind::Set ? fold.n : rate_basis(kind, fold)) / seconds
      when "count" then fold.n
      when "avg" then fold.n.positive? ? fold.sum / fold.n : nil
      when "min" then fold.min
      when "max" then fold.max
      when "last" then fold.sum_of_lasts
      else
        sketch = fold.sketch
        sketch&.quantile(Compute::PERCENTILES.fetch(compute.fn), total: fold.n.to_i)
      end
    end

    # A counter's rate is its increments per second; a distribution's is its
    # observations per second.
    sig { params(kind: Kind, fold: Fold).returns(Float) }
    def rate_basis(kind, fold) = kind == Kind::Counter ? fold.sum : fold.n

    sig { params(compute: Compute, unit: T.nilable(String)).returns(T.nilable(String)) }
    def unit_for(compute, unit)
      case compute.fn
      when "rate" then "per_second"
      when "count" then nil
      else unit
      end
    end
  end
end
