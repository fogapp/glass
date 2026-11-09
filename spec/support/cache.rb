# typed: false
# frozen_string_literal: true

# The test environment defaults to a null cache store, which would make the
# circuit breaker (and anything else cache-backed) silently no-op — a spec
# could "pass" while testing nothing. Give specs a real in-memory store,
# cleared between examples.
RSpec.configure do |config|
  # AppSetting memoizes for 30s on hot paths; a stale memo would leak a
  # previous example's storage path into the next one.
  config.after { AppSetting.bust_cache! }

  config.around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end
end
