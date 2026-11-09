# typed: strict
# frozen_string_literal: true

module Telemetry
  # The series dictionary: one row per (app, metric name, tag set).
  class MetricSeries < TelemetryRecord
    extend T::Sig

    self.table_name = "metric_series"

    class Kind < T::Enum
      include ApplicationEnum
      enums do
        Counter = new("counter")
        Gauge = new("gauge")
        Dist = new("dist")
        Set = new("set")
      end
    end

    # The identity of a tag set, independent of key order: what the unique
    # index is on. 63 bits of SHA-256 — a bigint, never negative.
    sig { params(tags: T::Hash[String, String]).returns(Integer) }
    def self.tags_hash(tags)
      canonical = tags.sort.map { |key, value| "#{key}\u0000#{value}" }.join("\u0001")
      Telemetry.digest63(canonical)
    end
  end
end
