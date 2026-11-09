# typed: strict
# frozen_string_literal: true

module Query
  # The one reading of a time and of a range, for every endpoint and tool
  # that takes them. The console sends Unix seconds; an agent thinks in
  # clock times and in "the last hour", so a bound is any of:
  #
  #   "-15m", "-2h", "-7d", "now-30m"   that long before now (s, m, h, d, w)
  #   "now"
  #   "2026-09-30T03:00:00Z"            ISO 8601 — UTC when it names no offset
  #   1790737200, "1790737200.5"        Unix seconds
  #
  # What cannot be read raises Query::Invalid naming the parameter, so a
  # garbage `from` is a 422 the asker can act on rather than 1970.
  module Bounds
    extend T::Sig

    RELATIVE = /\A(?:now)?\s*-\s*(\d+(?:\.\d+)?)\s*(s|m|h|d|w)\z/
    UNITS = T.let({ "s" => 1, "m" => 60, "h" => 3_600, "d" => 86_400, "w" => 604_800 }.freeze, T::Hash[String, Integer])
    EPOCH = /\A\d{9,}(?:\.\d+)?\z/

    # [from, to]. `to` defaults to now; `from` to `default` before `to` — or,
    # with no default, both are required. With `max`, a range wider than it
    # is refused.
    sig do
      params(
        from: T.untyped, to: T.untyped, default: T.nilable(ActiveSupport::Duration),
        max: T.nilable(ActiveSupport::Duration), now: Time
      ).returns([ Time, Time ])
    end
    def self.resolve(from:, to:, default: nil, max: nil, now: Time.now.utc)
      # `from` is read first, so a missing pair names `from`.
      since = T.let(from.nil? && default ? nil : parse(from, "from", now), T.nilable(Time))
      upto = to.nil? && default ? now : parse(to, "to", now)
      since = upto - (default || 0) if since.nil?
      check!(since, upto, max: max)
      [ since, upto ]
    end

    # A range that ends before it starts, or one wider than `max`, is the
    # asker's to fix.
    sig { params(from: Time, to: Time, max: T.nilable(ActiveSupport::Duration)).void }
    def self.check!(from, to, max: nil)
      raise Invalid, "The range ends before it starts — “from” must be earlier than “to”" if to <= from
      return if max.nil? || to - from <= max.to_f

      raise Invalid, "The range is wider than #{max.in_days.to_i} days — narrow it"
    end

    sig { params(value: T.untyped, name: String, now: Time).returns(Time) }
    def self.parse(value, name, now = Time.now.utc)
      case value
      when nil then raise Invalid, "“#{name}” is required: #{FORMS}"
      when Numeric then Time.at(value.to_f).utc
      when String then text(value.strip, name, now)
      else raise Invalid, unreadable(name, value)
      end
    end

    FORMS = "ISO 8601 (2026-09-30T03:00:00Z), Unix seconds, a relative time (-15m, -2h, -7d), or “now”"

    sig { params(value: String, name: String, now: Time).returns(Time) }
    def self.text(value, name, now)
      lowered = value.downcase
      return now if lowered == "now"
      if (match = RELATIVE.match(lowered))
        return now - T.must(match[1]).to_f * UNITS.fetch(T.must(match[2]))
      end
      return Time.at(value.to_f).utc if EPOCH.match?(value)

      Time.find_zone!("UTC").iso8601(value).utc
    rescue ArgumentError
      raise Invalid, unreadable(name, value)
    end
    private_class_method :text

    sig { params(name: String, value: T.untyped).returns(String) }
    def self.unreadable(name, value)
      "“#{name}” is not a time: #{value.inspect} — use #{FORMS}"
    end
    private_class_method :unreadable
  end
end
