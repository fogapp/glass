# typed: strict
# frozen_string_literal: true

module Telemetry
  # A browser session, assembled from its events as they arrive
  # (Ingest::Visits).
  class Visit < TelemetryRecord
    self.table_name = "visits"
    self.primary_key = nil
  end
end
