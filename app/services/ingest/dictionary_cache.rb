# typed: strict
# frozen_string_literal: true

module Ingest
  # What a process remembers of a dictionary (metric series, profile
  # functions and stacks): content key → id, so only an entry never seen
  # before costs a query.
  #
  # Telemetry::Dictionaries' safety invariant (1) rests on this class: every
  # id it answers was looked up, or created, within
  # Telemetry::Dictionaries::CACHE_TTL. So the whole cache is forgotten at
  # once — when it has been filling for longer than that, and when it grows
  # past its limit — and the clock starts again; nothing is ever kept from
  # an earlier fill. Read on every use, so a spec can shorten it.
  #
  # Thread-safe: every read and write holds one lock, and the lock is never
  # held across a query — callers look up what is missing between
  # `fetch_many` and `remember`.
  class DictionaryCache
    extend T::Sig
    extend T::Generic

    Key = type_member

    sig { params(limit: Integer).void }
    def initialize(limit:)
      @limit = limit
      @lock = T.let(Mutex.new, Mutex)
      @entries = T.let({}, T::Hash[Key, Integer])
      @filled_at = T.let(clock, Float)
    end

    # The ids remembered for those keys; a key not remembered is absent.
    sig { params(keys: T::Array[Key]).returns(T::Hash[Key, Integer]) }
    def fetch_many(keys)
      @lock.synchronize do
        forget if expired?
        keys.each_with_object({}) do |key, out|
          id = @entries[key]
          out[key] = id if id
        end
      end
    end

    sig { params(entries: T::Hash[Key, Integer]).void }
    def remember(entries)
      return if entries.empty?

      @lock.synchronize do
        forget if expired? || @entries.size + entries.size > @limit
        @entries.merge!(entries)
      end
    end

    sig { void }
    def reset!
      @lock.synchronize { forget }
    end

    private

    # Callers hold the lock.
    sig { returns(T::Boolean) }
    def expired?
      clock - @filled_at > Telemetry::Dictionaries::CACHE_TTL.to_f
    end

    # Callers hold the lock.
    sig { void }
    def forget
      @entries = {}
      @filled_at = clock
    end

    sig { returns(Float) }
    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
  end
end
