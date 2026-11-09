source "https://rubygems.org"

gem "rails", "~> 8.1.3"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Sorbet runtime (static tools live in the development group)
gem "sorbet-runtime"

# Error reporting to Fog's built-in tracker. Vendored (synced from
# fog's clients/flare) so Docker builds need no gem host; inert without the
# FLARE_DSN env Fog injects, so dev/test are unaffected.
gem "flare", path: "vendor/gems/flare"

# Glass observes itself with its own client, from the
# canonical source in this repo — the same gem every other app vendors at
# vendor/gems/glass. Inert without GLASS_URL + GLASS_API_KEY. After `rails`:
# its railtie only loads if Rails is already defined.
gem "glass", path: "clients/ruby"

# Household sign-in through fog's OpenID provider (fog-signin/1): the shared
# relying party and its Rails controller. Vendored (synced from
# fog's clients/fog-client) for the same reason as flare; inert without
# OIDC_ISSUER, so dev/test are unaffected. Explicit require: the gem's entry
# file is fog_client.rb, which Bundler's default (require "fog-client") misses.
gem "fog-client", path: "vendor/gems/fog-client", require: "fog_client"

# Free/total space for Settings › Storage: the disk budget is only honest
# next to how much room there actually is.
gem "sys-filesystem"

# Passkey (WebAuthn) authentication.
#
# require: false — webauthn drags in five attestation/COSE gems (tpm-key_
# attestation, safety_net_attestation, android_key_attestation, cose, bindata)
# for ~12 MB of heap, and only the two passkey controllers ever touch it.
# WebauthnRelyingParty requires it in a before_action, so the worker container
# and every non-passkey request boot without it.
gem "webauthn", "~> 3.4", require: false

# Official MCP SDK (maintained with Shopify) for the agent surface.
# Rack-native: a server is assembled per request inside McpController,
# stateless JSON mode — no sessions, fog-swap safe.
gem "mcp"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache and Active Job
gem "solid_cache"
gem "solid_queue"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  gem "rspec-rails"
  gem "sorbet", require: false
  gem "tapioca", require: false

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  gem "rubocop-sorbet", require: false
end

group :test do
  # No real network in specs, ever
  gem "webmock"
  # Coverage ratchet: opt-in with COVERAGE=1.
  gem "simplecov", require: false
end
