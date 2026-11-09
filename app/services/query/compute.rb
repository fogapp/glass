# typed: strict
# frozen_string_literal: true

module Query
  # One thing to compute: `count`, `p95(duration)`, `uniq(user)`,
  # `error_rate`, `apdex(250)`, `ratio(cache_read, input_total)`. The text a person wrote is also the key the
  # answer is returned under, so a chart's legend reads the way its query
  # did.
  class Compute < T::Struct
    extend T::Sig

    PERCENTILES = T.let({ "p50" => 0.5, "p75" => 0.75, "p90" => 0.9, "p95" => 0.95, "p99" => 0.99 }.freeze,
      T::Hash[String, Float])
    FIELD_FUNCTIONS = T.let((%w[sum avg min max] + PERCENTILES.keys).freeze, T::Array[String])
    EVENT_FUNCTIONS = T.let((%w[count rate errors error_rate apdex uniq ratio] + FIELD_FUNCTIONS).freeze, T::Array[String])
    # Functions that answer zero, not "no data", for a bucket with no rows:
    # nothing happening is a count of nothing.
    ZERO_WHEN_EMPTY = T.let(%w[count rate sum uniq errors].freeze, T::Array[String])
    DEFAULT_APDEX_MS = 500.0
    FORMAT = /\A([a-z_0-9]+)(?:\(([^()]*)\))?\z/

    const :key, String
    const :fn, String
    const :arg, T.nilable(String)

    sig { params(text: String).returns(Compute) }
    def self.parse(text)
      match = FORMAT.match(text.strip.downcase) || raise(Invalid, "Cannot read “#{text}” — expected something like p95(duration)")
      new(key: text.strip.downcase, fn: T.must(match[1]), arg: match[2].presence&.strip)
    end

    sig { returns(T::Boolean) }
    def zero_when_empty? = ZERO_WHEN_EMPTY.include?(fn)

    # The unit the answer is in, for the console's formatting.
    sig { params(source: Sources::Source).returns(T.nilable(String)) }
    def unit(source)
      case fn
      when "rate" then "per_second"
      when "error_rate" then "ratio"
      when "apdex" then "score"
      when "ratio" then "ratio"
      when *FIELD_FUNCTIONS then source.field(arg.to_s)&.unit
      end
    end

    # The aggregate as SQL. `seconds` is the width of what is being
    # aggregated — one bucket of a timeseries, or the whole range of a table
    # — which is what makes `rate` a rate.
    sig { params(source: Sources::Source, seconds: Float).returns(String) }
    def sql(source, seconds:)
      weight = source.weight_sql
      total = source.count_sql
      # Nothing happening is a count of nothing, not the absence of a count.
      case fn
      when "count" then "coalesce(#{total}, 0)::float8"
      when "rate" then "(coalesce(#{total}, 0) / #{seconds.to_f})::float8"
      when "errors"
        status!(source)
        "coalesce(#{filtered(total, "status = 'error'")}, 0)::float8"
      when "error_rate"
        status!(source)
        "(coalesce(#{filtered(total, "status = 'error'")}, 0)::float8 / nullif(#{total}, 0))"
      when "apdex" then apdex_sql(source, total)
      when "uniq" then "count(DISTINCT #{dimension!(source).sql})::float8"
      when "ratio" then ratio_sql(source)
      when "sum" then "coalesce(sum(#{measure!(source).sql} * #{weight}), 0)::float8"
      # Cast before dividing: a whole-number column over a whole-number
      # count is integer division, and the mean of 1 and 2 is not 1.
      when "avg" then "(sum(#{measure!(source).sql} * #{weight})::float8 / nullif(#{total}, 0))"
      when "min", "max" then "#{fn}(#{measure!(source).sql})::float8"
      when *PERCENTILES.keys
        "percentile_cont(#{PERCENTILES.fetch(fn)}) WITHIN GROUP (ORDER BY #{measure!(source).sql})::float8"
      else
        raise Invalid, "Unknown function “#{fn}” — one of #{EVENT_FUNCTIONS.join(', ')}"
      end
    end

    private

    sig { params(total: String, condition: String).returns(String) }
    def filtered(total, condition) = "#{total} FILTER (WHERE #{condition})"

    # Satisfied + half of tolerating, over everything: the standard score,
    # with the threshold in milliseconds as the argument. A second argument
    # names the time to judge — `apdex(2000, active)` scores a run by how
    # long the app took, not by how long a person took to answer it.
    sig { params(source: Sources::Source, total: String).returns(String) }
    def apdex_sql(source, total)
      text, name = arg.to_s.split(",", 2).map(&:strip)
      duration = name.nil? ? source.field("duration") : measure!(source, name)
      raise Invalid, "apdex needs a source with durations" if duration.nil?

      threshold = T.let(text.blank? ? DEFAULT_APDEX_MS : Float(text, exception: false), T.nilable(Float))
      raise Invalid, "apdex takes a threshold in milliseconds, like apdex(250)" if threshold.nil? || threshold <= 0

      satisfied = filtered(total, "#{duration.sql} <= #{threshold}")
      tolerating = filtered(total, "#{duration.sql} > #{threshold} AND #{duration.sql} <= #{threshold * 4}")
      "((coalesce(#{satisfied}, 0) + coalesce(#{tolerating}, 0) / 2.0) / nullif(#{total}, 0))::float8"
    end

    # One total over another: the share of input tokens read from cache,
    # of tool calls that failed. A ratio of sums — never a mean of each
    # row's ratio, which weighs a ten-token call like a ten-thousand-token
    # one.
    sig { params(source: Sources::Source).returns(String) }
    def ratio_sql(source)
      names = arg.to_s.split(",").map(&:strip)
      raise Invalid, "ratio takes two numbers, like ratio(cache_read, input_total)" unless names.size == 2 && names.none?(&:empty?)

      top, bottom = names.map { |name| "sum(#{measure!(source, name).sql} * #{source.weight_sql})::float8" }
      "(#{top} / nullif(#{bottom}, 0))"
    end

    sig { params(source: Sources::Source, field_name: T.nilable(String)).returns(Sources::Field) }
    def measure!(source, field_name = arg)
      name = field_name || raise(Invalid, "#{fn} needs a field, like #{fn}(duration)")
      field = source.field(name)
      return field if field&.numeric?

      measures = source.fields.select(&:measure).map(&:name).join(", ")
      raise Invalid, "#{fn}(#{name}): “#{name}” is not a number in #{source.name} — try #{measures}"
    end

    sig { params(source: Sources::Source).returns(Sources::Field) }
    def dimension!(source)
      name = arg || raise(Invalid, "uniq needs a field, like uniq(user)")
      source.field(name) || raise(Invalid, "uniq(#{name}): #{source.name} has no “#{name}”")
    end

    sig { params(source: Sources::Source).void }
    def status!(source)
      raise Invalid, "#{fn} needs a source that records a status" unless source.status?
    end
  end
end
