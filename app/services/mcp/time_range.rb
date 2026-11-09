# typed: strict
# frozen_string_literal: true

module Mcp
  # The time range of a tool call, read the way every endpoint reads one
  # (Query::Bounds): ISO 8601, Unix seconds, "-15m", "now". An agent is asked
  # "why was hook slow at 3 am?" and thinks in clock times and in "the last
  # hour", so a tool's range always has a default span before now.
  #
  # What cannot be read raises Query::Invalid, which a tool hands back as a
  # sentence the agent can act on.
  module TimeRange
    extend T::Sig

    DEFAULT_SPAN = T.let(1.hour, ActiveSupport::Duration)

    # [from, to]. `to` defaults to now; `from` to `default` before `to`.
    # With `max`, a range wider than it is refused (Query::Bounds.check!).
    sig do
      params(from: T.untyped, to: T.untyped, default: ActiveSupport::Duration, max: T.nilable(ActiveSupport::Duration),
        now: Time).returns([ Time, Time ])
    end
    def self.resolve(from:, to:, default: DEFAULT_SPAN, max: nil, now: Time.now.utc)
      Query::Bounds.resolve(from: from, to: to, default: default, max: max, now: now)
    end

    # An optional bound: nil when none was given.
    sig { params(value: T.untyped, name: String, now: Time).returns(T.nilable(Time)) }
    def self.optional(value, name, now: Time.now.utc) = value.nil? ? nil : Query::Bounds.parse(value, name, now)
  end
end
