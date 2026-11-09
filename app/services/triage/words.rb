# typed: strict
# frozen_string_literal: true

module Triage
  # Numbers as a sentence says them: "1,204", "640 ms", "1.4 s", "12.3%".
  # The console formats its own figures; these are for titles, summaries
  # and the brief an agent reads, which are prose.
  module Words
    extend T::Sig

    sig { params(value: T.untyped).returns(String) }
    def self.count(value) = ActiveSupport::NumberHelper.number_to_delimited(value.to_f.round)

    sig { params(value: T.untyped).returns(String) }
    def self.ms(value)
      ms = value.to_f
      if ms >= 60_000 then "#{trim(ms / 60_000, 1)} min"
      elsif ms >= 1_000 then "#{trim(ms / 1_000, ms >= 10_000 ? 0 : 1)} s"
      else "#{trim(ms, ms >= 10 ? 0 : 1)} ms"
      end
    end

    # A stretch of hours as hours: "15.9 h" where `ms` would say "955 min".
    sig { params(value: T.untyped).returns(String) }
    def self.elapsed(value)
      ms = value.to_f
      ms >= 2 * 3_600_000 ? "#{trim(ms / 3_600_000, ms >= 36_000_000 ? 0 : 1)} h" : self.ms(ms)
    end

    sig { params(value: T.untyped).returns(String) }
    def self.percent(value)
      share = value.to_f * 100
      "#{trim(share, share >= 10 ? 0 : 1)}%"
    end

    sig { params(value: T.untyped).returns(String) }
    def self.times(value)
      "#{trim(value.to_f, value.to_f >= 10 ? 0 : 1)}×"
    end

    sig { params(value: T.untyped).returns(String) }
    def self.usd(value) = format("$%.2f", value.to_f)

    # 9.0 → "9", 4.25 → "4.3": no trailing zeros.
    sig { params(value: Float, digits: Integer).returns(String) }
    def self.trim(value, digits) = ActiveSupport::NumberHelper.number_to_rounded(value, precision: digits, strip_insignificant_zeros: true)

    # A long string as one line of a title.
    sig { params(text: T.untyped, length: Integer).returns(String) }
    def self.clip(text, length = 90) = text.to_s.squish.truncate(length)

    # "request" → "requests"; the noun a kind of work is counted in
    # (Telemetry::Work::Kind#counted).
    sig { params(kind: T.untyped, count: T.untyped).returns(String) }
    def self.noun(kind, count) = Telemetry::Work.kind(kind.to_s).counted(count)
  end
end
