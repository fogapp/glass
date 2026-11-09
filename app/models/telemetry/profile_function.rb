# typed: strict
# frozen_string_literal: true

module Telemetry
  # A function named by some profile, once per app.
  class ProfileFunction < TelemetryRecord
    extend T::Sig

    self.table_name = "profile_functions"

    # Whose code a function is: the app's, a dependency's (`gem`, whatever
    # the language calls one), the runtime's own (`ruby`, `node`), or
    # something below the runtime.
    CATEGORIES = T.let(%w[app gem ruby node native].freeze, T::Array[String])

    # Identity (the `digest` column): name and file. 63 bits of SHA-256.
    sig { params(name: String, file: String).returns(Integer) }
    def self.identity(name, file)
      Telemetry.digest63("#{name}\u0000#{file}")
    end
  end
end
