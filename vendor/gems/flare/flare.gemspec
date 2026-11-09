# frozen_string_literal: true

require_relative "lib/flare/version"

Gem::Specification.new do |s|
  s.name        = "flare"
  s.version     = Flare::VERSION
  s.summary     = "Error reporting to Fog's built-in tracker"
  s.description = "Zero-dependency Rails error reporter. Subscribes to Rails.error and ships " \
                  "Sentry-schema events to the FLARE_DSN Fog injects into every managed app."
  s.authors     = ["Matthew Werner"]
  s.homepage    = "https://github.com/fogapp/fog"
  s.license     = "MIT"
  s.files       = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  s.required_ruby_version = ">= 3.2"
  # No runtime dependencies, ever — this gem rides inside every app and must
  # not be able to conflict with anything they use.
end
