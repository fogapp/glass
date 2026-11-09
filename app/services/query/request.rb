# typed: strict
# frozen_string_literal: true

module Query
  # A query as asked: what the console posts to /api/v1/query.
  class Request < T::Struct
    extend T::Sig

    class Shape < T::Enum
      include ApplicationEnum
      enums do
        Timeseries = new("timeseries")
        Table = new("table")
        List = new("list")
        Heatmap = new("heatmap")
        Histogram = new("histogram")
      end
    end

    MAX_RANGE = T.let(800.days, ActiveSupport::Duration)
    MAX_GROUPS = 3
    # Room for a breakdown and the figures beside it: a run's seven phases
    # with its count, its percentiles and its cost are one table.
    MAX_COMPUTES = 20
    DEFAULT_LIMIT = T.let({ Shape::Timeseries => 10, Shape::Table => 50, Shape::List => 100 }.freeze, T::Hash[Shape, Integer])
    MAX_LIMIT = 500

    const :source, String
    const :shape, Shape
    const :from, Time
    const :to, Time
    const :filter, String
    const :computes, T::Array[Compute]
    const :group_by, T::Array[String]
    const :step, T.nilable(Integer)
    const :limit, Integer
    # A compute key, `-`-prefixed for descending. nil: the first compute,
    # descending.
    const :order, T.nilable(String)
    # The metric a `metrics` query reads.
    const :metric, T.nilable(String)
    # The measure a heatmap or histogram buckets.
    const :field, T.nilable(String)
    # list: only rows strictly older than this.
    const :before, T.nilable(Time)

    sig { params(params: T::Hash[String, T.untyped]).returns(Request) }
    def self.from_params(params)
      shape = Shape.try_deserialize(params["shape"].to_s) ||
        raise(Invalid, "Unknown shape “#{params['shape']}” — one of #{Shape.values.map(&:serialize).join(', ')}")
      from, to = Bounds.resolve(from: params["from"], to: params["to"], max: MAX_RANGE)

      computes = list(params["compute"]).map { |text| Compute.parse(text) }
      raise Invalid, "At most #{MAX_COMPUTES} things can be computed at once" if computes.size > MAX_COMPUTES

      group_by = list(params["group_by"])
      raise Invalid, "Group by at most #{MAX_GROUPS} fields" if group_by.size > MAX_GROUPS

      requested_limit = params["limit"].is_a?(Numeric) ? params["limit"].to_i : nil
      new(
        source: params["source"].to_s, shape: shape, from: from, to: to, filter: params["filter"].to_s,
        computes: computes, group_by: group_by,
        step: params["step"].is_a?(Numeric) ? params["step"].to_i : nil,
        limit: (requested_limit || DEFAULT_LIMIT.fetch(shape, 50)).clamp(1, MAX_LIMIT),
        order: params["order"].is_a?(String) ? params["order"].strip.downcase.presence : nil,
        metric: params["metric"].is_a?(String) ? params["metric"].strip.presence : nil,
        field: params["field"].is_a?(String) ? params["field"].strip.presence : nil,
        before: params["before"].nil? ? nil : Bounds.parse(params["before"], "before")
      )
    end

    sig { returns(Float) }
    def seconds = (to - from).to_f

    sig { params(value: T.untyped).returns(T::Array[String]) }
    def self.list(value)
      case value
      when String then value.strip.empty? ? [] : [ value ]
      when Array then value.grep(String).map(&:strip).reject(&:empty?)
      else []
      end
    end
    private_class_method :list
  end
end
