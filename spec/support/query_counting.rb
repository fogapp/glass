# typed: false
# frozen_string_literal: true

# Counting queries is how a preload stays a preload.
#
# An N+1 does not fail a test — it makes one slightly slower — so the only way
# a fix for one survives is if something asserts the shape rather than the
# result. These helpers exist so that assertion can be written in a line.
module QueryCounting
  # SCHEMA and TRANSACTION rows are the adapter talking to itself, not the code
  # under test, and their number varies with what happens to be cached.
  IGNORED = /\A(SCHEMA|TRANSACTION)\z/

  def count_queries(matching: nil)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name].to_s.match?(IGNORED)
      next if matching && !payload[:sql].to_s.match?(matching)

      queries << payload[:sql]
    end
    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    queries
  end
end

RSpec.configure do |config|
  config.include QueryCounting
end
