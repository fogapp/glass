# typed: strict
# frozen_string_literal: true

# What an app's agents are told to do — the directives half of
# glass-ingest/1. Changed in Glass's console, delivered in
# the reply to every flush, so a setting reaches every process of an app
# within ten seconds and without a deploy.
#
# The app row stores only what a person changed (`apps.agent_settings`);
# this struct is those overrides over the defaults.
class AgentSettings < T::Struct
  extend T::Sig

  # Keep the span tree of one ordinary trace in this many (errors, slow
  # outliers and first-sight endpoints are always kept).
  const :trace_sample_rate, Float, default: 0.1
  # Profiling on at all, and at what rate.
  const :profiling, T::Boolean, default: true
  const :profile_hz, Integer, default: 100
  # The least severe log level shipped.
  const :log_level, String, default: "info"
  # Inject glass.js into HTML responses.
  const :browser, T::Boolean, default: true

  LOG_LEVELS = T.let(%w[debug info warn error off].freeze, T::Array[String])
  # The bounds of each numeric setting, by name: a value outside is clamped
  # to the nearer end.
  RANGES = T.let({
    "trace_sample_rate" => (0.0..1.0),
    "profile_hz" => (10..1000)
  }.freeze, T::Hash[String, T::Range[T.untyped]])

  # The stored overrides over the defaults, read the way they were written
  # (coerce_overrides), so what a person saved is what the agents are told.
  sig { params(overrides: T::Hash[String, T.untyped]).returns(AgentSettings) }
  def self.from_overrides(overrides) = new(**coerce_overrides(overrides).symbolize_keys)

  # What a person sent as overrides, made fit to store: only the settings
  # this struct declares, each in the type it declares and inside its
  # range. A value that cannot be one of them (a log level "loud", a rate
  # "abc") is left out — the setting keeps what it was, as a read would
  # have ignored it anyway.
  sig { params(raw: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def self.coerce_overrides(raw)
    props.each_with_object({}) do |(name, rules), out|
      key = name.to_s
      next unless raw.key?(key)

      value = coerce(key, rules[:type], raw[key])
      out[key] = value unless value.nil?
    end
  end

  sig { params(key: String, type: T.untyped, value: T.untyped).returns(T.untyped) }
  def self.coerce(key, type, value)
    if type == Float || type == Integer
      parsed = T.let(Float(value.to_s, exception: false), T.nilable(Float))
      return nil unless parsed&.finite?

      number = type == Integer ? parsed.to_i : parsed
      range = RANGES[key]
      range ? number.clamp(range.begin, range.end) : number
    elsif type == T::Boolean
      ActiveModel::Type::Boolean.new.cast(value) ? true : false
    elsif key == "log_level"
      LOG_LEVELS.include?(value.to_s) ? value.to_s : nil
    else
      value.to_s
    end
  end
  private_class_method :coerce

  # The settings as the console shows and edits them.
  sig { returns(T::Hash[String, T.untyped]) }
  def to_h
    {
      "trace_sample_rate" => trace_sample_rate, "profiling" => profiling, "profile_hz" => profile_hz,
      "log_level" => log_level, "browser" => browser
    }
  end
end
