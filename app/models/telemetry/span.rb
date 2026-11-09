# typed: strict
# frozen_string_literal: true

module Telemetry
  # A child span of a kept trace — the waterfall.
  class Span < TelemetryRecord
    self.table_name = "spans"
    self.primary_key = nil

    # What a span can be a step of. The first six are an app's own
    # plumbing; the rest are the steps of an agent's run.
    # Anything else is stored as `custom`.
    KINDS = T.let(%w[sql view cache http enqueue custom model tool wait queue memory context sandbox channel].freeze,
      T::Array[String])
  end
end
