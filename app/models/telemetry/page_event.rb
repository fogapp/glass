# typed: strict
# frozen_string_literal: true

module Telemetry
  # One thing a visitor did in the browser.
  class PageEvent < TelemetryRecord
    self.table_name = "page_events"
    self.primary_key = nil

    KINDS = T.let(%w[pageview click submit vital custom error].freeze, T::Array[String])
    # What a visit counts as its visitor doing something (Visit#interactions).
    INTERACTIONS = T.let(%w[click submit custom].freeze, T::Array[String])
    DEVICES = T.let(%w[phone tablet desktop].freeze, T::Array[String])
  end
end
