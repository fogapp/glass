# frozen_string_literal: true

# Flare: error reporting to Fog's built-in tracker.
#
# The whole client in one sentence: a Rails.error subscriber builds
# Sentry-schema events and a single background thread POSTs them to the
# FLARE_DSN Fog injects — bounded queue, drop on overflow, so reporting can
# never hurt the app doing the reporting. No configuration is required; no
# DSN means the gem is inert (development, test, apps run outside Fog).
#
# Wire-compatible with Sentry on purpose: point the official sentry-ruby SDK
# at the same DSN and the server can't tell the difference.

require_relative "flare/version"
require_relative "flare/config"
require_relative "flare/event_builder"
require_relative "flare/transport"
require_relative "flare/subscriber"
require_relative "flare/railtie" if defined?(Rails::Railtie)

module Flare
  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
    end

    def enabled?
      config.enabled?
    end

    # Manual reporting for rescued errors the Rails reporter never sees
    # (or for use outside Rails entirely). Never raises.
    def notify(exception, handled: true, severity: :error, context: {}, source: nil, fingerprint: nil)
      return nil unless enabled? && exception.is_a?(Exception)
      event = EventBuilder.new(config).build(
        exception, handled: handled, severity: severity, context: context,
        source: source, fingerprint: fingerprint
      )
      transport.enqueue(event)
      nil
    rescue StandardError => e
      config.logger&.warn("flare: notify failed: #{e.class}: #{e.message}")
      nil
    end

    # Attach key/values to every report in the current execution (delegates
    # to Rails' reporter context when available).
    def context(**kv)
      if defined?(Rails) && Rails.respond_to?(:error)
        Rails.error.set_context(**kv)
      end
      nil
    end

    # Drain the queue, waiting at most `timeout` seconds. Called at exit so
    # a crash-then-terminate still reports.
    def flush(timeout: 2)
      @transport&.flush(timeout: timeout)
    end

    def transport
      @transport ||= Transport.new(config)
    end

    # Test hook: forget all state, including the worker thread.
    def reset!
      @transport&.shutdown
      @transport = nil
      @config = nil
    end
  end
end

at_exit { Flare.flush(timeout: 2) if Flare.enabled? }
