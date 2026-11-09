# typed: strict
# frozen_string_literal: true

module Telemetry
  # A call stack named by some profile, once per app: function ids, root
  # first.
  class ProfileStack < TelemetryRecord
    extend T::Sig

    self.table_name = "profile_stacks"

    sig { params(frames: T::Array[Integer]).returns(Integer) }
    def self.identity(frames)
      Telemetry.digest63(frames.pack("l>*"))
    end
  end
end
