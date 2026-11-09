# typed: strict
# frozen_string_literal: true

module Telemetry
  # The 5-minute rollup tier (Telemetry::Rollup). Same shape as MetricPoint.
  class MetricPoint5m < TelemetryRecord
    self.table_name = "metric_points_5m"
    self.primary_key = nil
  end
end
