# typed: strict
# frozen_string_literal: true

module Telemetry
  # How much of a profiling window one stack accounted for.
  class ProfileSample < TelemetryRecord
    self.table_name = "profile_samples"
    self.primary_key = nil

    STATES = T.let(%w[running stalled idle gc].freeze, T::Array[String])
  end
end
