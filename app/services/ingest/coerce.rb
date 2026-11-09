# typed: strict
# frozen_string_literal: true

module Ingest
  # Turning what an agent sent into what a column holds. An agent is another
  # program's bug away from sending anything, so nothing here trusts a type:
  # every reader answers a clean value or nil, and the record builders decide
  # whether nil means "skip the record" or "leave the column empty".
  module Coerce
    extend T::Sig

    MAX_ATTRS = 64
    MAX_ATTR_KEY = 80
    MAX_ATTR_VALUE = 1_000
    MAX_TAGS = 20
    MAX_TAG_VALUE = 200
    # Postgres real: anything a duration could honestly be, and finite.
    MAX_MS = 1.0e9
    MAX_COST = 1.0e6

    HEX32 = /\A[0-9a-f]{32}\z/
    HEX16 = /\A[0-9a-f]{16}\z/
    # Sorbet cannot read a literal past 2**62, so these are computed (and
    # `2**63` is an Integer to Ruby, whatever Sorbet's `**` sig says).
    TWO_63 = T.let(T.unsafe(2)**63, Integer)
    TWO_64 = Telemetry::TWO_64

    sig { params(value: T.untyped, max: Integer).returns(T.nilable(String)) }
    def self.str(value, max: 200)
      return nil unless value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric)

      text = value.to_s.delete("\u0000")
      text.empty? ? nil : text[0, max]
    end

    sig { params(value: T.untyped).returns(T.nilable(Float)) }
    def self.float(value)
      return nil unless value.is_a?(Numeric)

      number = value.to_f
      number.finite? ? number : nil
    end

    # A non-negative duration in milliseconds.
    sig { params(value: T.untyped).returns(T.nilable(Float)) }
    def self.ms(value)
      number = float(value)
      number&.clamp(0.0, MAX_MS)
    end

    # An amount of money in US dollars: never negative, and never so large
    # that one broken agent could make a year's spend unreadable.
    sig { params(value: T.untyped).returns(T.nilable(Float)) }
    def self.cost(value)
      number = float(value)
      number&.clamp(0.0, MAX_COST)
    end

    sig { params(value: T.untyped, max: Integer).returns(T.nilable(Integer)) }
    def self.int(value, max: 2_147_483_647)
      case value
      when Integer then value.clamp(0, max)
      when Float then value.finite? ? value.to_i.clamp(0, max) : nil
      end
    end

    sig { params(value: T.untyped).returns(T::Boolean) }
    def self.bool(value) = value == true

    # One of a closed vocabulary, or `default` for anything else.
    sig do
      type_parameters(:D)
        .params(value: T.untyped, list: T::Array[String], default: T.type_parameter(:D))
        .returns(T.any(String, T.type_parameter(:D)))
    end
    def self.one_of(value, list, default) = list.include?(value) ? value : default

    # A unit of work's outcome: "error" when the agent said so, else "ok".
    sig { params(value: T.untyped).returns(String) }
    def self.status(value) = value == "error" ? "error" : "ok"

    # A trace id as the uuid the column holds.
    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def self.trace_id(value)
      return nil unless value.is_a?(String) && HEX32.match?(value)

      "#{value[0, 8]}-#{value[8, 4]}-#{value[12, 4]}-#{value[16, 4]}-#{value[20, 12]}"
    end

    # A span id as the signed bigint the column holds (64 bits of hex,
    # two's complement — the mapping is reversible, see Telemetry.span_hex).
    sig { params(value: T.untyped).returns(T.nilable(Integer)) }
    def self.span_id(value)
      return nil unless value.is_a?(String) && HEX16.match?(value)

      unsigned = value.to_i(16)
      unsigned >= TWO_63 ? unsigned - TWO_64 : unsigned
    end

    # Flat string → scalar. Nested values are stringified rather than
    # dropped: a truncated answer beats a missing one when reading a trace.
    sig { params(value: T.untyped).returns(T::Hash[String, T.untyped]) }
    def self.attrs(value)
      return {} unless value.is_a?(Hash)

      value.to_a.first(MAX_ATTRS).each_with_object({}) do |(key, raw), out|
        name = str(key, max: MAX_ATTR_KEY)
        next if name.nil?

        out[name] =
          case raw
          when true, false then raw
          when Integer then raw.clamp(-2**53, 2**53)
          when Float then raw.finite? ? raw : nil
          when nil then nil
          when String then raw.delete("\u0000")[0, MAX_ATTR_VALUE]
          else raw.to_json[0, MAX_ATTR_VALUE]
          end
      end.compact
    end

    # Metric tags: string → string, a bounded number of them.
    sig { params(value: T.untyped).returns(T::Hash[String, String]) }
    def self.tags(value)
      return {} unless value.is_a?(Hash)

      value.to_a.first(MAX_TAGS).each_with_object({}) do |(key, raw), out|
        name = str(key, max: MAX_ATTR_KEY)
        text = str(raw == true || raw == false ? raw.to_s : raw, max: MAX_TAG_VALUE)
        out[name] = text if name && text
      end
    end
  end
end
