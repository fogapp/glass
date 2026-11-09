# typed: strict
# frozen_string_literal: true

module Telemetry
  # One log line or structured event, tied to the trace that wrote it.
  class LogLine < TelemetryRecord
    self.table_name = "logs"
    self.primary_key = nil

    LEVELS = T.let(%w[debug info warn error fatal].freeze, T::Array[String])
  end
end
