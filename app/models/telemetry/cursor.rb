# typed: strict
# frozen_string_literal: true

module Telemetry
  # A worker pass's checkpoint over telemetry. Advanced only when the pass
  # committed — a checkpoint never moves on failure (house invariant 1).
  class Cursor < TelemetryRecord
    extend T::Sig

    self.table_name = "cursors"
    self.primary_key = "name"

    sig { params(name: String).returns(T.nilable(ActiveSupport::TimeWithZone)) }
    def self.position(name) = find_by(name: name)&.position

    sig { params(name: String, position: T.any(Time, ActiveSupport::TimeWithZone)).void }
    def self.advance!(name, position)
      upsert({ name: name, position: position, updated_at: Time.current }, unique_by: :name) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
