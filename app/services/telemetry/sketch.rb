# typed: strict
# frozen_string_literal: true

module Telemetry
  # A DDSketch: a distribution summarized as counts in logarithmic buckets,
  # with a guaranteed *relative* error on any quantile (here ~1%). The
  # property that matters is that two sketches merge by adding their buckets
  # — so a p95 over many series, many processes or many rolled-up windows is
  # computed from the merged distribution, never by averaging p95s.
  #
  # The mapping is fixed for the whole system (GAMMA); the agent's sketch
  # (clients/ruby/lib/glass/sketch.rb) uses the same constant, and
  # spec/services/telemetry/sketch_spec.rb pins the two together.
  #
  # Wire and storage form: a flat integer array of alternating bucket index
  # and count, ascending by index — `integer[]` in metric_points.sketch.
  # Values at or below MIN_VALUE have no bucket; they are the point's `n`
  # minus the sketch's total, and read as zero.
  class Sketch
    extend T::Sig

    GAMMA = 1.02
    LOG_GAMMA = T.let(Math.log(GAMMA), Float)
    MIN_VALUE = 1e-9

    sig { returns(T::Hash[Integer, Integer]) }
    attr_reader :buckets

    sig { params(buckets: T::Hash[Integer, Integer]).void }
    def initialize(buckets = {})
      @buckets = buckets
    end

    sig { params(pairs: T.nilable(T::Array[Integer])).returns(Sketch) }
    def self.from_pairs(pairs)
      sketch = new
      sketch.merge_pairs!(pairs) if pairs
      sketch
    end

    sig { params(value: Float).returns(T.nilable(Integer)) }
    def self.index_for(value)
      return nil if value <= MIN_VALUE

      (Math.log(value) / LOG_GAMMA).ceil
    end

    # The value a bucket stands for: the midpoint (in relative terms) of
    # (GAMMA^(i-1), GAMMA^i].
    sig { params(index: Integer).returns(Float) }
    def self.value_for(index) = 2.0 * (GAMMA**index) / (GAMMA + 1.0)

    sig { params(value: Float, count: Integer).void }
    def add(value, count = 1)
      index = Sketch.index_for(value)
      @buckets[index] = @buckets.fetch(index, 0) + count if index
    end

    sig { params(index: Integer, count: Integer).void }
    def add_bucket(index, count)
      @buckets[index] = @buckets.fetch(index, 0) + count if count.positive?
    end

    sig { params(pairs: T::Array[Integer]).void }
    def merge_pairs!(pairs)
      pairs.each_slice(2) do |index, count|
        next if index.nil? || count.nil? || count <= 0

        @buckets[index] = @buckets.fetch(index, 0) + count
      end
    end

    sig { params(other: Sketch).void }
    def merge!(other)
      other.buckets.each { |index, count| @buckets[index] = @buckets.fetch(index, 0) + count }
    end

    sig { returns(Integer) }
    def count = @buckets.values.sum

    sig { returns(T::Boolean) }
    def empty? = @buckets.empty?

    # The q-quantile (0..1) of a distribution of `total` values, of which
    # the sketch holds the positive ones; the remainder are zeros and sort
    # first. nil when there is nothing to take a quantile of.
    sig { params(quantile: Float, total: T.nilable(Integer)).returns(T.nilable(Float)) }
    def quantile(quantile, total: nil)
      held = count
      total = [ total || held, held ].max
      return nil if total.zero?

      rank = (quantile.clamp(0.0, 1.0) * (total - 1)).floor
      zeros = total - held
      return 0.0 if rank < zeros

      seen = zeros
      @buckets.sort.each do |index, bucket_count|
        seen += bucket_count
        return Sketch.value_for(index) if seen > rank
      end
      last = @buckets.keys.max
      last ? Sketch.value_for(last) : 0.0
    end

    sig { returns(T::Array[Integer]) }
    def to_pairs = @buckets.sort.flatten
  end
end
