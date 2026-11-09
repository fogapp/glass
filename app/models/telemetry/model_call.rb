# typed: strict
# frozen_string_literal: true

module Telemetry
  # One call to a model: what was asked for and
  # what answered, the tokens and what they cost, the shape of the latency,
  # and why the call was made. Every call is kept — a retry, a reviewer, a
  # title — because spend is only exact when nothing is sampled away.
  class ModelCall < TelemetryRecord
    self.table_name = "model_calls"
    self.primary_key = nil
  end
end
