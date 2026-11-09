# typed: strict
# frozen_string_literal: true

module Query
  # How wide a timeseries bucket is. Asked for, or chosen so a chart has
  # enough points to show shape and few enough to draw and to query.
  module Step
    extend T::Sig

    LADDER = T.let([ 10, 30, 60, 300, 900, 1_800, 3_600, 10_800, 21_600, 43_200, 86_400 ].freeze, T::Array[Integer])
    TARGET_POINTS = 180
    MAX_POINTS = 1_500

    sig { params(from: Time, to: Time, requested: T.nilable(Integer)).returns(Integer) }
    def self.for(from:, to:, requested: nil)
      span = (to - from).to_f
      if requested
        raise Invalid, "step must be at least 1 second" if requested < 1
        raise Invalid, "That step makes more than #{MAX_POINTS} points — widen it or narrow the range" if span / requested > MAX_POINTS

        return requested
      end
      LADDER.find { |step| span / step <= TARGET_POINTS } || T.must(LADDER.last)
    end

    # Bucket starts covering [from, to), aligned to the step so the same
    # range asked twice answers with the same buckets.
    sig { params(from: Time, to: Time, step: Integer).returns(T::Array[Integer]) }
    def self.times(from:, to:, step:)
      first = from.to_i - (from.to_i % step)
      (first...to.to_i).step(step).to_a
    end
  end
end
