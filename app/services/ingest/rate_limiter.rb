# typed: strict
# frozen_string_literal: true

module Ingest
  # The server's one back-pressure valve: a fixed
  # window per ingest key, answered with 429 + Retry-After, which every
  # agent honours by pausing and dropping.
  #
  # Counted in process memory, not in Solid Cache: this runs on every batch
  # from every process in the fleet, and a database write per batch to
  # decide whether to allow a database write would be the dominant cost of
  # ingest. The price is that the limit is per web process — during a
  # blue-green swap two replicas each allow a full window. A limit that is
  # briefly double is still a limit.
  class RateLimiter
    extend T::Sig

    WINDOW = 60
    # A healthy agent flushes every 10 s: 6 batches a minute per process.
    # 600 is a hundred processes on one key before anyone is turned away.
    MAX_BATCHES = 600
    MAX_RECORDS = 300_000

    class Verdict < T::Struct
      const :allowed, T::Boolean
      const :retry_after, Integer
    end

    Counter = T.type_alias { [ Integer, Integer, Integer ] } # window start, batches, records

    @windows = T.let({}, T::Hash[String, Counter])
    @lock = T.let(Mutex.new, Mutex)

    class << self
      extend T::Sig

      sig { void }
      def reset!
        @lock.synchronize { @windows = {} }
      end

      # Count one batch against the key. Records are charged afterwards
      # (charge), once the batch has been parsed and its size is known.
      sig { params(key_id: String, now: Integer).returns(Verdict) }
      def check(key_id, now: Time.now.to_i)
        window = now - (now % WINDOW)
        @lock.synchronize do
          start, batches, records = @windows[key_id] || [ window, 0, 0 ]
          start, batches, records = window, 0, 0 if start != window
          over = batches >= MAX_BATCHES || records >= MAX_RECORDS
          @windows[key_id] = [ start, batches + (over ? 0 : 1), records ]
          Verdict.new(allowed: !over, retry_after: [ window + WINDOW - now, 1 ].max)
        end
      end

      sig { params(key_id: String, records: Integer, now: Integer).void }
      def charge(key_id, records, now: Time.now.to_i)
        window = now - (now % WINDOW)
        @lock.synchronize do
          start, batches, counted = @windows[key_id] || [ window, 0, 0 ]
          @windows[key_id] = [ start, batches, counted + records ] if start == window
        end
      end
    end
  end
end
