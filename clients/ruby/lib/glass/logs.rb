# frozen_string_literal: true

require "logger"
require "json"
require_relative "attrs"

module Glass
  # Log shipping: a sink on the app's broadcast logger for plain log lines
  # (`src: "rails"`) and a Rails.event subscriber for structured events
  # (`src: "event"`). Both carry the current trace and span so a trace can
  # show its own logs. Guarded against feeding on itself — nothing written
  # on the agent thread or from inside the agent is shipped — and against
  # volume: the log buffer is bounded, overflow drops and counts.
  module Logs
    LEVELS = %w[debug info warn error fatal fatal].freeze
    ANSI = /\e\[[0-9;]*[A-Za-z]/
    MAX_MESSAGE = 8_000
    MAX_ATTRS = 64
    # Never shipped from an event payload, whatever the app's filters say:
    # bind values, params, and the request/response objects that carry
    # headers and cookies.
    DROP_KEYS = %w[binds type_casted_binds params parameters headers request response cookies].freeze
    MUTE = :glass_muted

    class << self
      def attach(config)
        if config.feature?(:logs) && ::Rails.respond_to?(:logger) && ::Rails.logger.respond_to?(:broadcast_to)
          sink = Sink.new(config)
          sink.floor = ::Rails.logger.level rescue 0
          ::Rails.logger.broadcast_to(sink)
        end
        if config.feature?(:events) && ::Rails.respond_to?(:event) && ::Rails.event.respond_to?(:subscribe)
          ::Rails.event.subscribe(EventSubscriber.new(config))
        end
      rescue StandardError => e
        Glass.error("logs", e)
      end

      def record(severity, message)
        return if Thread.current[:glass_agent] || Thread.current[MUTE]
        msg = text(message)
        return if msg.empty?
        rec = { t: "log", ts: Time.now.to_f, lvl: LEVELS[severity.clamp(0, 5)], msg: msg, src: "rails" }
        stamp(rec)
        Glass.transport.push(:log, rec)
      end

      def stamp(rec)
        txn = Tracer.current
        return unless txn
        rec[:trace] = txn.trace_id
        rec[:span] = txn.current_span_hex
      end

      def text(message)
        s =
          case message
          when String then message
          when Exception then "#{message.class}: #{message.message}"
          when nil then ""
          else message.inspect
          end
        s = s.gsub(ANSI, "") if s.include?("\e")
        s = s.strip
        s.size > MAX_MESSAGE ? s[0, MAX_MESSAGE] : s
      end

      # Run a block with the agent's own logging muted, so a line the agent
      # writes about itself never becomes a record. Test seam: the agent's own
      # paths set the flag directly (the error reporter, the middleware).
      def muted
        Thread.current[MUTE] = true
        yield
      ensure
        Thread.current[MUTE] = nil
      end
    end

    # Logger-compatible enough for ActiveSupport::BroadcastLogger. Its level
    # is never below the app's own: BroadcastLogger#level is the minimum
    # over its sinks, and a lower one here would switch on debug logging —
    # every SQL statement formatted — across the whole app.
    class Sink < ::Logger
      attr_accessor :floor

      def initialize(config)
        super(nil)
        @config = config
        @floor = 0
      end

      def level
        [@config.log_threshold, @floor].max
      end

      def level=(value)
        @floor = value.is_a?(Integer) ? value : ::Logger::Severity.const_get(value.to_s.upcase) rescue @floor
      end

      def local_level=(value)
        Thread.current[:glass_log_local_level] = value
      end

      def local_level
        Thread.current[:glass_log_local_level]
      end

      def add(severity, message = nil, progname = nil)
        severity ||= ::Logger::UNKNOWN
        threshold = local_level || level
        return true if severity < threshold
        if message.nil?
          if block_given?
            message = yield
          else
            message = progname
          end
        end
        Logs.record(severity, message)
        true
      rescue StandardError => e
        Glass.error("log", e)
        true
      end
      alias log add

      def <<(message)
        Logs.record(::Logger::UNKNOWN, message) if ::Logger::UNKNOWN >= level
        true
      rescue StandardError
        true
      end

      def close; end
      def reopen(*); self; end
    end

    # Rails.event (8.1): one `log` record per event, the name as the
    # message, the payload flattened and scrubbed into attrs.
    class EventSubscriber
      def initialize(config)
        @config = config
      end

      def emit(event)
        return unless Glass.enabled?
        return if Thread.current[:glass_agent] || Thread.current[MUTE]
        return if @config.log_threshold > 1 # events are info
        ts = event[:timestamp]
        rec = {
          t: "log", ts: ts.is_a?(Numeric) ? ts / 1_000_000_000.0 : Time.now.to_f,
          lvl: "info", msg: event[:name].to_s[0, MAX_MESSAGE], src: "event"
        }
        attrs = flatten(@config.scrub(payload_hash(event[:payload])))
        tags = event[:tags]
        if tags.is_a?(Hash) && !tags.empty?
          tags.each { |k, v| attrs["tag.#{k}"] = Attrs.scalar(v) if attrs.size < MAX_ATTRS }
        end
        rec[:attrs] = attrs unless attrs.empty?
        Logs.stamp(rec)
        Glass.transport.push(:log, rec)
      rescue StandardError => e
        Glass.error("event", e)
      end

      private

      def payload_hash(payload)
        case payload
        when Hash then payload
        when nil then {}
        else
          if payload.respond_to?(:serialize) then h = payload.serialize
          elsif payload.respond_to?(:to_h) then h = payload.to_h
          end
          h.is_a?(Hash) ? h : { "payload" => payload.class.name }
        end
      rescue StandardError
        {}
      end

      def flatten(hash)
        out = {}
        hash.each do |k, v|
          key = k.to_s
          next if DROP_KEYS.include?(key)
          break if out.size >= MAX_ATTRS
          out[key] = key == "sql" && v.is_a?(String) ? Sql.normalize(v) : Attrs.scalar(v)
        end
        out
      end
    end
  end
end
