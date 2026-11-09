# typed: strict
# frozen_string_literal: true

module Query
  # Runs a query and answers in the shape asked for. Every statement carries
  # the time range (so partitions prune) and a statement timeout (so one
  # careless query cannot sit on the Postgres every app shares).
  class Runner
    extend T::Sig

    TIMEOUT_MS = 8_000
    HEATMAP_BUCKETS = 36
    HISTOGRAM_BUCKETS = 48
    # Below this a log scale has nowhere to start.
    MIN_POSITIVE = 0.01

    Row = T.type_alias { T::Hash[String, T.untyped] }

    sig { params(request: Request, context: Context).returns(T::Hash[Symbol, T.untyped]) }
    def self.run(request, context)
      answer = request.source == "metrics" ? Metrics.new(request, context).run : new(request, context).run
      # Which apps it read, when its filter confined it: what a chart's
      # markers and its label name.
      apps = context.apps_in(request.filter)
      apps ? answer.merge(apps: apps) : answer
    end

    sig { params(request: Request, context: Context).void }
    def initialize(request, context)
      @request = request
      @context = context
      @source = T.let(Sources.fetch(request.source), Sources::Source)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def run
      shape = @request.shape
      case shape
      when Request::Shape::Table then table
      when Request::Shape::Timeseries then timeseries
      when Request::Shape::List then list
      when Request::Shape::Heatmap then heatmap
      when Request::Shape::Histogram then histogram
      else T.absurd(shape)
      end
    end

    # Executes under the statement timeout. Shared with Metrics.
    sig { params(sql: String).returns(T::Array[Row]) }
    def self.select(sql) = timed { TelemetryRecord.connection.select_all(sql).to_a }

    # Whatever `read` sends to the telemetry database, under the statement
    # timeout; one that runs past it is Invalid, saying so. Shared with
    # Traces::Lookup, whose statements are Active Record's.
    sig do
      type_parameters(:U).params(slow: String, read: T.proc.returns(T.type_parameter(:U))).returns(T.type_parameter(:U))
    end
    def self.timed(slow: "narrow the time range or add a filter", &read)
      TelemetryRecord.transaction do
        TelemetryRecord.connection.execute("SET LOCAL statement_timeout = #{TIMEOUT_MS}")
        read.call
      end
    rescue ActiveRecord::QueryCanceled
      raise Invalid, "That query took longer than #{TIMEOUT_MS / 1000} seconds — #{slow}"
    end

    private

    # One SQL statement, bound. A Statement's binds are numbered as they
    # are made and belong to the one SQL they were made for, so every
    # statement the runner sends compiles through here with a Where and a
    # Statement of its own — none is ever shared between two.
    sig { params(build: T.proc.params(where: Where, statement: Statement).returns(String)).returns(String) }
    def compile(&build)
      statement = Statement.new
      statement.to_sql(build.call(Where.new(source: @source, context: @context, statement: statement), statement))
    end

    sig { returns(T::Array[Compute]) }
    def computes = @request.computes.presence || [ Compute.parse("count") ]

    # ---- table -----------------------------------------------------------

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def table
      { shape: "table", from: @request.from.to_f, to: @request.to.to_f,
        columns: group_columns + compute_columns, rows: table_rows(@request.limit) }
    end

    sig { params(limit: Integer).returns(T::Array[Row]) }
    def table_rows(limit)
      groups = @request.group_by
      order = order_sql
      sql = compile do |where, _|
        selects = groups.each_with_index.map { |name, index| "#{where.expression(name)} AS g#{index}" }
        selects += computes.each_with_index.map { |compute, index| "#{compute.sql(@source, seconds: @request.seconds)} AS c#{index}" }
        text = +"SELECT #{selects.join(', ')} FROM #{@source.table} WHERE #{range_sql(where)}"
        text << " GROUP BY #{(1..groups.size).to_a.join(', ')}" if groups.any?
        text << " ORDER BY #{order} LIMIT #{limit}"
      end

      Runner.select(sql).map do |row|
        out = T.let({}, Row)
        groups.each_with_index { |name, index| out[name] = group_value(name, row["g#{index}"]) }
        computes.each_with_index { |compute, index| out[compute.key] = row["c#{index}"] }
        out
      end
    end

    # `-p95(duration)` descending, `name` ascending; by default the first
    # compute, largest first — the ranking a top list wants.
    sig { returns(String) }
    def order_sql
      order = @request.order
      return "c0 DESC NULLS LAST" if order.nil?

      descending = order.start_with?("-")
      key = order.delete_prefix("-")
      direction = descending ? "DESC NULLS LAST" : "ASC NULLS LAST"
      if (index = computes.index { |compute| compute.key == key })
        "c#{index} #{direction}"
      elsif (index = @request.group_by.index(key))
        "g#{index} #{direction}"
      else
        raise Invalid, "Cannot order by “#{key}” — it is not one of the computed or grouped fields"
      end
    end

    # ---- timeseries ------------------------------------------------------

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def timeseries
      step = Step.for(from: @request.from, to: @request.to, requested: @request.step)
      times = Step.times(from: @request.from, to: @request.to, step: step)
      groups = @request.group_by
      top = groups.any? ? table_rows(@request.limit).map { |row| groups.map { |name| row[name] } } : [ [] ]

      index_of = times.each_with_index.to_h
      series = top.flat_map do |group|
        computes.map do |compute|
          { key: compute.key, group: groups.zip(group).to_h, unit: compute.unit(@source),
            values: Array.new(times.size, compute.zero_when_empty? ? 0.0 : nil) }
        end
      end
      slot = top.each_with_index.to_h

      timeseries_rows(step, top).each do |row|
        position = index_of[row["bucket"].to_i]
        group_index = slot[groups.each_with_index.map { |name, index| group_value(name, row["g#{index}"]) }]
        next if position.nil? || group_index.nil?

        computes.each_with_index do |_, index|
          value = row["c#{index}"]
          T.must(series[group_index * computes.size + index])[:values][position] = value unless value.nil?
        end
      end

      { shape: "timeseries", from: @request.from.to_f, to: @request.to.to_f, step: step, times: times, series: series }
    end

    # One statement for every bucket of every kept group.
    sig { params(step: Integer, top: T::Array[T::Array[T.untyped]]).returns(T::Array[Row]) }
    def timeseries_rows(step, top)
      groups = @request.group_by
      return [] if groups.any? && top.empty?

      sql = compile do |where, statement|
        selects = [ "#{time_bucket_sql(step)} AS bucket" ]
        selects += groups.each_with_index.map { |name, index| "#{where.expression(name)} AS g#{index}" }
        selects += computes.each_with_index.map { |compute, index| "#{compute.sql(@source, seconds: step.to_f)} AS c#{index}" }

        conditions = [ range_sql(where) ]
        conditions << "(#{top.map { |group| group_match(where, statement, group) }.join(' OR ')})" if groups.any?

        "SELECT #{selects.join(', ')} FROM #{@source.table} WHERE #{conditions.join(' AND ')} " \
          "GROUP BY #{(1..groups.size + 1).to_a.join(', ')}"
      end
      Runner.select(sql)
    end

    # One top group as a condition. IS NOT DISTINCT FROM so a group whose
    # value is NULL ("no route") is matched like any other.
    sig { params(where: Where, statement: Statement, group: T::Array[T.untyped]).returns(String) }
    def group_match(where, statement, group)
      parts = @request.group_by.zip(group).map do |name, value|
        "#{where.expression(name)} IS NOT DISTINCT FROM #{statement.bind(raw_group_value(name, value))}"
      end
      "(#{parts.join(' AND ')})"
    end

    # ---- list ------------------------------------------------------------

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def list
      fields = @source.list_fields.map { |name| @source.field!(name) }
      selects = [ "extract(epoch FROM ts)::float8 AS ts" ] + fields.map { |field| "#{field.sql} AS #{field.name}" }
      if (attrs = @source.attrs)
        selects << "#{attrs} AS attrs"
      end
      order = list_order_sql
      sql = compile do |where, statement|
        conditions = [ range_sql(where) ]
        if (before = @request.before)
          conditions << "ts < #{statement.bind(before)}"
        end
        "SELECT #{selects.join(', ')} FROM #{@source.table} WHERE #{conditions.join(' AND ')} ORDER BY #{order} LIMIT #{@request.limit}"
      end

      rows = Runner.select(sql).map { |row| list_row(row, fields) }
      { shape: "list", from: @request.from.to_f, to: @request.to.to_f, rows: rows,
        # The cursor for the next page, when this one was full — only a
        # time-ordered list pages; a ranked one is its top N.
        next_before: rows.size == @request.limit && @request.order.nil? ? rows.last&.fetch("ts") : nil }
    end

    # Newest first by default; `-duration` ranks the rows by a measure
    # instead (the slowest requests), `duration` the other way.
    sig { returns(String) }
    def list_order_sql
      order = @request.order
      return "ts DESC" if order.nil?

      field = @source.field!(order.delete_prefix("-"))
      raise Invalid, "A list can only be ranked by a number — “#{field.name}” is not one" unless field.numeric?

      "#{field.sql} #{order.start_with?('-') ? 'DESC' : 'ASC'} NULLS LAST, ts DESC"
    end

    sig { params(row: Row, fields: T::Array[Sources::Field]).returns(Row) }
    def list_row(row, fields)
      out = T.let({ "ts" => row["ts"] }, Row)
      fields.each { |field| out[field.name] = list_value(field, row[field.name]) }
      if @source.attrs
        attrs = row["attrs"]
        out["attrs"] = attrs.is_a?(String) ? JSON.parse(attrs) : (attrs || {})
      end
      out
    end

    sig { params(field: Sources::Field, value: T.untyped).returns(T.untyped) }
    def list_value(field, value)
      return nil if value.nil?

      case field.type
      when Sources::Type::App then @context.slug(value)
      when Sources::Type::Trace then value.to_s.delete("-")
      else %w[span parent].include?(field.name) ? Telemetry.span_hex(value.to_i) : value
      end
    end

    # ---- heatmap and histogram -------------------------------------------

    # Counts by time and by value, the value on a log scale: the picture
    # that shows a second mode an average would hide.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def heatmap
      field = measure_field
      step = Step.for(from: @request.from, to: @request.to, requested: @request.step)
      times = Step.times(from: @request.from, to: @request.to, step: step)
      base = { shape: "heatmap", from: @request.from.to_f, to: @request.to.to_f, step: step, times: times,
               field: field.name, unit: field.unit }
      rows = bucketed(field, HEATMAP_BUCKETS, by_time: step)
      return base.merge(edges: [], cells: []) if rows.empty?

      index_of = times.each_with_index.to_h
      cells = rows.filter_map do |row|
        position = index_of[row["bucket"].to_i]
        position && [ position, row["slot"].to_i, row["n"].to_f ]
      end
      base.merge(edges: edges(T.must(rows.first), HEATMAP_BUCKETS), cells: cells)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def histogram
      field = measure_field
      base = { shape: "histogram", from: @request.from.to_f, to: @request.to.to_f, field: field.name, unit: field.unit }
      rows = bucketed(field, HISTOGRAM_BUCKETS)
      return base.merge(edges: [], counts: []) if rows.empty?

      counts = Array.new(HISTOGRAM_BUCKETS, 0.0)
      rows.each { |row| counts[row["slot"].to_i] = row["n"].to_f }
      base.merge(edges: edges(T.must(rows.first), HISTOGRAM_BUCKETS), counts: counts)
    end

    sig { returns(Sources::Field) }
    def measure_field
      name = @request.field || "duration"
      field = @source.field!(name)
      raise Invalid, "“#{name}” is not a number — a #{@request.shape.serialize} needs one" unless field.numeric?

      field
    end

    # Counts by log-scale slot of `field` (and by time bucket, given a
    # step), one statement: a CTE finds the range the scale spans — the
    # smallest positive value (never below MIN_POSITIVE) to the largest —
    # and every row answers it alongside, as the logarithms the slots were
    # cut by, so the edges drawn are the edges counted. No rows when there
    # is nothing positive to scale. Values at or below the low bound
    # (zeros included) fall in the first slot.
    sig { params(field: Sources::Field, slots: Integer, by_time: T.nilable(Integer)).returns(T::Array[Row]) }
    def bucketed(field, slots, by_time: nil)
      value = "(#{field.sql})::float8"
      sql = compile do |where, _|
        seen = "SELECT min(#{value}) FILTER (WHERE #{value} > 0) AS low, max(#{value}) AS high " \
               "FROM #{@source.table} WHERE #{range_sql(where)}"
        floored = "SELECT greatest(low, #{MIN_POSITIVE}::float8) AS low, high FROM seen WHERE low IS NOT NULL AND high > 0"
        widened = "SELECT low, greatest(high, low * 1.0001::float8) AS high FROM floored"
        slot = "least(greatest(width_bucket(ln(greatest(#{value}, scale.low)), scale.ln_low, scale.ln_high, #{slots}), 1), #{slots}) - 1"
        selects = [ by_time && "#{time_bucket_sql(by_time)} AS bucket", "#{slot} AS slot", "#{count_sql} AS n",
                    "scale.ln_low", "scale.ln_high" ].compact
        groups = (1..selects.size - 3).to_a + %w[scale.ln_low scale.ln_high]
        "WITH seen AS (#{seen}), floored AS (#{floored}), widened AS (#{widened}), " \
          "scale AS (SELECT low, ln(low) AS ln_low, ln(high) AS ln_high FROM widened) " \
          "SELECT #{selects.join(', ')} FROM #{@source.table} CROSS JOIN scale " \
          "WHERE #{range_sql(where)} AND #{field.sql} IS NOT NULL GROUP BY #{groups.join(', ')}"
      end
      Runner.select(sql)
    end

    # The slots' edges, from the logarithms the statement cut them by.
    sig { params(row: Row, slots: Integer).returns(T::Array[Float]) }
    def edges(row, slots)
      ln_low = row["ln_low"].to_f
      span = row["ln_high"].to_f - ln_low
      (0..slots).map { |index| Math.exp(ln_low + span * index / slots) }
    end

    # ---- shared ----------------------------------------------------------

    # The request's range, apps and filter, bound into `where`'s statement.
    sig { params(where: Where).returns(String) }
    def range_sql(where) = where.sql(from: @request.from, to: @request.to, filter: @request.filter)

    sig { params(step: Integer).returns(String) }
    def time_bucket_sql(step) = "extract(epoch FROM date_bin('#{step} seconds', ts, TIMESTAMPTZ 'epoch'))::bigint"

    sig { returns(String) }
    def count_sql = @source.count_sql

    # What a group's value is to the console: an app is its slug.
    sig { params(name: String, value: T.untyped).returns(T.untyped) }
    def group_value(name, value)
      return value if name.start_with?("@")

      @source.field!(name).type == Sources::Type::App ? @context.slug(value) : value
    end

    # …and back, to match it in SQL.
    sig { params(name: String, value: T.untyped).returns(T.untyped) }
    def raw_group_value(name, value)
      return value if name.start_with?("@") || value.nil?

      @source.field!(name).type == Sources::Type::App ? @context.app_id(value.to_s) : value
    end

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def group_columns
      @request.group_by.map do |name|
        label = name.start_with?("@") ? name : @source.field!(name).label
        { key: name, label: label, kind: "dimension" }
      end
    end

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def compute_columns
      computes.map { |compute| { key: compute.key, label: compute.key, kind: "measure", unit: compute.unit(@source) } }
    end
  end
end
