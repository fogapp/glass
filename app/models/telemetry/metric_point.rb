# typed: strict
# frozen_string_literal: true

module Telemetry
  # One series' summary for one flush window (10 s as flushed by agents).
  class MetricPoint < TelemetryRecord
    self.table_name = "metric_points"
    self.primary_key = nil
  end
end
