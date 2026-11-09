# frozen_string_literal: true

module Glass
  # A memo shared by every thread, bounded by clearing when full: cheaper
  # than any eviction, and right for what it holds — a home fleet's handful
  # of statements, addresses, hosts and user agents, where a miss costs one
  # recomputation. The value is computed outside the lock, so two threads
  # missing the same key at once both compute it (harmlessly); nil and false
  # are remembered like any other answer.
  class BoundedCache
    MISS = Object.new.freeze

    def initialize(max)
      @max = max
      @map = {}
      @mutex = Mutex.new
    end

    def fetch(key)
      hit = @mutex.synchronize { @map.fetch(key, MISS) }
      return hit unless MISS.equal?(hit)
      value = yield(key)
      @mutex.synchronize do
        @map.clear if @map.size >= @max
        @map[key] = value
      end
      value
    end

    def size
      @mutex.synchronize { @map.size }
    end

    def clear
      @mutex.synchronize { @map.clear }
    end
  end
end
