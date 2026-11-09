# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # A `metric` record → a point, still naming its series by (name, tags):
    # SeriesResolver turns that into a series id before the write.
    module Metric
      extend T::Sig

      NAME_FORMAT = /\A[a-zA-Z][a-zA-Z0-9_.:\-]{0,119}\z/
      MAX_SKETCH_BUCKETS = 2_048
      MAX_BUCKET_VALUE = 2_147_483_648 # Postgres integer

      class Point < T::Struct
        const :ts, Time
        const :name, String
        const :kind, Telemetry::MetricSeries::Kind
        const :unit, T.nilable(String)
        const :tags, T::Hash[String, String]
        const :n, Integer
        const :sum, Float
        const :min, T.nilable(Float)
        const :max, T.nilable(Float)
        const :last, T.nilable(Float)
        const :sketch, T.nilable(T::Array[Integer])
      end

      sig { params(record: Record, context: Context).returns(T.nilable(Point)) }
      def self.build(record, context)
        name = record["name"]
        kind = Telemetry::MetricSeries::Kind.try_deserialize(record["kind"].to_s)
        return nil unless name.is_a?(String) && NAME_FORMAT.match?(name) && kind

        Point.new(
          ts: context.time(record), name: name, kind: kind, unit: Coerce.str(record["unit"], max: 20),
          tags: Coerce.tags(record["tags"]),
          n: Coerce.int(record["n"], max: Batch::MAX_COUNT) || 0, sum: Coerce.float(record["sum"]) || 0.0,
          min: Coerce.float(record["min"]), max: Coerce.float(record["max"]), last: Coerce.float(record["last"]),
          sketch: kind == Telemetry::MetricSeries::Kind::Dist ? sketch(record["sk"]) : nil
        )
      end

      # Alternating index, count — kept only if it is exactly that.
      sig { params(value: T.untyped).returns(T.nilable(T::Array[Integer])) }
      def self.sketch(value)
        return nil unless value.is_a?(Array) && value.size.even? && value.size <= MAX_SKETCH_BUCKETS * 2
        return nil unless value.all? { |item| item.is_a?(Integer) && item.abs < MAX_BUCKET_VALUE }

        value
      end
      private_class_method :sketch
    end
  end
end
