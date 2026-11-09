# frozen_string_literal: true

module Glass
  # A DDSketch: counts in logarithmic buckets, with a ~1% relative error on
  # any quantile. The mapping is fixed for the whole system and must match
  # the server's Telemetry::Sketch exactly (app/services/telemetry/sketch.rb):
  # sketches merge by adding counts, so a percentile over many processes and
  # windows is computed from one merged distribution, never by averaging.
  #
  # Wire form: a flat integer array of alternating bucket index and count,
  # ascending by index. Values at or below MIN_VALUE have no bucket; they are
  # the series' `n` minus the sketch's total and read as zero.
  class Sketch
    GAMMA = 1.02
    LOG_GAMMA = Math.log(GAMMA)
    MIN_VALUE = 1e-9
    # The server rejects a sketch past this many buckets. The full index
    # range of 1e-9..1e9 is ~2,100 buckets, so only a pathological series
    # gets here; the lowest buckets are folded up to stay under it.
    MAX_BUCKETS = 2_048

    attr_reader :buckets, :count

    def initialize
      @buckets = {}
      @count = 0 # every value added, including the unbucketed ones
    end

    def self.index_for(value)
      return nil if value <= MIN_VALUE
      (Math.log(value) / LOG_GAMMA).ceil
    end

    # The value a bucket stands for: the relative midpoint of (γ^(i-1), γ^i].
    def self.value_for(index)
      2.0 * (GAMMA**index) / (GAMMA + 1.0)
    end

    def add(value)
      @count += 1
      index = Sketch.index_for(value)
      @buckets[index] = (@buckets[index] || 0) + 1 if index
      self
    end

    def empty?
      @count.zero?
    end

    # The q-quantile (0..1) over everything added; the unbucketed values are
    # zeros and sort first. Same arithmetic as the server's.
    def quantile(quantile)
      return nil if @count.zero?
      rank = (quantile.clamp(0.0, 1.0) * (@count - 1)).floor
      zeros = @count - @buckets.values.sum
      return 0.0 if rank < zeros
      seen = zeros
      @buckets.keys.sort.each do |index|
        seen += @buckets[index]
        return Sketch.value_for(index) if seen > rank
      end
      last = @buckets.keys.max
      last ? Sketch.value_for(last) : 0.0
    end

    def to_pairs
      keys = @buckets.keys.sort
      if keys.size > MAX_BUCKETS
        # Fold the lowest buckets into the lowest kept one: the tail that
        # matters for latency is the top.
        keep_from = keys.size - MAX_BUCKETS
        folded = keys[0...keep_from].sum { |k| @buckets[k] }
        keys = keys[keep_from..]
        first = keys.first
        return keys.flat_map { |k| [k, k == first ? @buckets[k] + folded : @buckets[k]] }
      end
      keys.flat_map { |k| [k, @buckets[k]] }
    end
  end
end
