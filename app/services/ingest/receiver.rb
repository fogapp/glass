# typed: strict
# frozen_string_literal: true

module Ingest
  # One batch, end to end: parse, write, account. The controller decides
  # what HTTP says about it.
  module Receiver
    extend T::Sig

    class Result < T::Struct
      const :accepted, Integer
      const :skipped, Integer
      # Records whose timestamp was unbelievable and were stamped on arrival.
      const :skewed, Integer
    end

    sig { params(key: IngestKey, text: String, now: Time).returns(Result) }
    def self.call(key:, text:, now: Time.now.utc)
      app = T.must(key.app)
      batch = Batch.parse(app: app, text: text, now: now)
      Writer.write!(app, batch)
      RateLimiter.charge(key.id, batch.accepted, now: now.to_i)
      key.record_use!
      app.record_seen!(now: now.in_time_zone)
      Result.new(accepted: batch.accepted, skipped: batch.skipped, skewed: batch.clock.skewed)
    end
  end
end
