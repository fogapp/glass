# frozen_string_literal: true

require_relative "lib/glass/version"

Gem::Specification.new do |s|
  s.name        = "glass"
  s.version     = Glass::VERSION
  s.summary     = "Metrics, traces, profiles, logs and visitor analytics for Glass"
  s.description = "The Glass agent for Rails apps: auto-instruments requests, SQL, jobs and the runtime, " \
                  "profiles continuously, and ships everything to the GLASS_URL with the GLASS_API_KEY. " \
                  "Inert without both."
  s.authors     = ["Matthew Werner"]
  s.homepage    = "https://github.com/fogapp/glass"
  s.license     = "MIT"
  s.files       = Dir["lib/**/*.rb", "lib/**/*.js", "README.md", "LICENSE"]
  s.required_ruby_version = ">= 3.2.1"
  # One runtime dependency, on purpose: a
  # sampler written in Ruby can only observe a thread once it has released
  # the GVL, so it attributes nearly all time to blocking calls — measured,
  # 99% to `sleep` against a truth of 4%. Vernier samples natively, has no
  # dependencies of its own, and is loaded lazily: if it cannot be loaded the
  # agent runs without profiles rather than not at all.
  s.add_dependency "vernier", ">= 1.8"
  s.add_development_dependency "minitest", "~> 5.16"
  s.add_development_dependency "rake", "~> 13.0"
end
