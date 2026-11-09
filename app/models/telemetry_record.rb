# typed: strict
# frozen_string_literal: true

# Base for everything in the telemetry database: signals,
# their dictionaries, heartbeats. A different database from ApplicationRecord
# — no foreign keys and no joins across the two; a row names its app by
# App#telemetry_id.
#
# Nothing here is HouseholdScoped: telemetry is reached through an App, and
# the App is what is scoped.
class TelemetryRecord < ApplicationRecord
  self.abstract_class = true

  connects_to database: { writing: :telemetry, reading: :telemetry }
end
