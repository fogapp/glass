# typed: strict
# frozen_string_literal: true

module Ingest
  # A record's own timestamp, when it is believable. Agents flush every ten
  # seconds on the same host as Glass, so a timestamp days off is a broken
  # clock or a broken agent, and it would land in a partition that does not
  # exist. Such a record is stamped with the time it arrived instead, and
  # counted — the batch result says how many, so skew is visible rather than
  # silently rewritten.
  class Clock
    extend T::Sig

    # Inside the partitions Telemetry::Partitions keeps ahead and behind.
    MAX_PAST = T.let(47.hours, ActiveSupport::Duration)
    MAX_FUTURE = T.let(10.minutes, ActiveSupport::Duration)

    sig { returns(Integer) }
    attr_reader :skewed

    # `max_past` is widened only by replays of history (the demo generator),
    # which create the partitions they write into.
    sig { params(now: Time, max_past: ActiveSupport::Duration).void }
    def initialize(now: Time.now.utc, max_past: MAX_PAST)
      @now = now
      @earliest = T.let((now - max_past).to_f, Float)
      @latest = T.let((now + MAX_FUTURE).to_f, Float)
      @skewed = T.let(0, Integer)
    end

    sig { returns(Time) }
    attr_reader :now

    sig { params(value: T.untyped).returns(Time) }
    def time(value)
      seconds = value.is_a?(Numeric) ? value.to_f : Float::NAN
      return Time.at(seconds).utc if seconds.finite? && seconds.between?(@earliest, @latest)

      @skewed += 1
      @now
    end
  end
end
