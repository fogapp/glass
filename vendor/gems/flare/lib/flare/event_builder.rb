# frozen_string_literal: true

require "json"
require "securerandom"
require "socket"
require "time"

module Flare
  # Builds a Sentry-schema event hash from an exception plus whatever
  # execution context the Rails reporter handed over. Runs on the caller's
  # thread, so everything here is bounded: capped cause chains, capped
  # messages, a capped source-file cache.
  class EventBuilder
    MAX_CAUSES = 5
    MAX_MESSAGE = 2000

    # Shared source-line cache: in-app frames get a few lines of context, and
    # a hot error would otherwise re-read the same files per occurrence.
    SOURCE_CACHE = {} # path -> Array[String]
    SOURCE_CACHE_MAX = 100
    SOURCE_MUTEX = Mutex.new

    def initialize(config)
      @config = config
    end

    def build(exception, handled:, severity:, context:, source:, fingerprint:)
      context ||= {}
      event = {
        event_id: SecureRandom.uuid.delete("-"),
        timestamp: Time.now.utc.iso8601,
        platform: "ruby",
        level: level_for(severity),
        server_name: hostname,
        environment: @config.environment,
        release: @config.release,
        transaction: transaction_from(context),
        exception: { values: chain(exception, handled: handled, source: source) },
        request: request_from(context),
        extra: extra_from(context),
      }
      event[:fingerprint] = Array(fingerprint) if fingerprint
      event.reject { |_, v| v.nil? || v == "" }
    end

    private

    def level_for(severity)
      case severity
      when :warning, :warn then "warning"
      when :info then "info"
      else "error"
      end
    end

    def hostname
      Socket.gethostname
    rescue StandardError
      nil
    end

    # Cause chain, Sentry's order: root cause first, the raised exception
    # last. `handled` describes the reported exception; its causes were by
    # definition wrapped, so they carry no mechanism of their own.
    def chain(exception, handled:, source:)
      list = []
      e = exception
      while e.is_a?(Exception) && list.size < MAX_CAUSES && !list.any? { |x| x.equal?(e) }
        list << e
        e = e.cause
      end
      list.reverse.map do |ex|
        value = {
          type: ex.class.name,
          value: ex.message.to_s[0, MAX_MESSAGE],
        }
        if ex.equal?(exception)
          value[:mechanism] = { type: source.to_s.empty? ? "generic" : source.to_s, handled: handled }
        end
        frames = frames_for(ex)
        value[:stacktrace] = { frames: frames } unless frames.empty?
        value
      end
    end

    # Ruby backtraces list the crash site first; Sentry frames go the other
    # way (oldest call first, crash last).
    def frames_for(ex)
      (ex.backtrace_locations || []).reverse.map { |loc| frame_for(loc) }
    end

    def frame_for(loc)
      abs = loc.absolute_path || loc.path || "?"
      root = @config.app_root
      in_app = abs.start_with?(root + "/") && !abs.include?("/vendor/") && !abs.include?("/.bundle/")
      frame = {
        filename: in_app ? abs.delete_prefix(root + "/") : abs,
        abs_path: abs,
        function: loc.label,
        lineno: loc.lineno,
        in_app: in_app,
      }
      # Source context only for in-app frames: it's our code, and it's what
      # makes the fog UI show the actual line instead of a path.
      if in_app && (ctx = source_context(abs, loc.lineno))
        frame.merge!(ctx)
      end
      frame
    end

    def source_context(path, lineno)
      lines = SOURCE_MUTEX.synchronize do
        SOURCE_CACHE.delete(path) if SOURCE_CACHE.size >= SOURCE_CACHE_MAX && !SOURCE_CACHE.key?(path)
        SOURCE_CACHE[path] ||= File.exist?(path) ? File.readlines(path, chomp: true) : nil
      end
      return nil unless lines
      i = lineno - 1
      return nil if i.negative? || i >= lines.size
      n = @config.context_lines
      {
        pre_context: lines[[i - n, 0].max...i] || [],
        context_line: lines[i],
        post_context: lines[(i + 1)..[i + n, lines.size - 1].min] || [],
      }
    rescue StandardError
      nil
    end

    # The Rails reporter auto-attaches :controller on request errors and
    # :job on ActiveJob errors — the two names that matter for grouping.
    def transaction_from(context)
      if (c = context[:controller]) && c.respond_to?(:action_name)
        "#{c.class.name}##{c.action_name}"
      elsif (j = context[:job])
        j.class.name
      elsif context[:transaction]
        context[:transaction].to_s
      end
    end

    def request_from(context)
      c = context[:controller]
      return nil unless c.respond_to?(:request) && c.request
      r = c.request
      # filtered_parameters applies the app's own filter_parameters config;
      # our scrub is a second pass with the built-in patterns.
      params = r.respond_to?(:filtered_parameters) ? r.filtered_parameters : {}
      {
        url: r.respond_to?(:url) ? r.url : nil,
        method: r.respond_to?(:request_method) ? r.request_method : nil,
        data: @config.scrub(jsonable(params)),
      }.compact
    rescue StandardError
      nil
    end

    # Everything else in the context hash rides along under extra, scrubbed
    # and coerced to JSON-safe values. Job details get stable names.
    def extra_from(context)
      extra = {}
      if (j = context[:job])
        extra[:job] = { class: j.class.name }
        extra[:job][:queue] = j.queue_name if j.respond_to?(:queue_name)
        extra[:job][:job_id] = j.job_id if j.respond_to?(:job_id)
      end
      context.each do |k, v|
        next if k == :controller || k == :job
        extra[k] = jsonable(v)
      end
      return nil if extra.empty?
      @config.scrub(extra)
    end

    # Context values can be arbitrary objects; the payload must be JSON.
    # Basic types pass through, everything else becomes its to_s — lossy on
    # purpose, an error report is not a serializer.
    def jsonable(obj, depth = 0)
      return "…" if depth > 6
      case obj
      when Hash then obj.to_h { |k, v| [k.to_s, jsonable(v, depth + 1)] }
      when Array then obj.first(50).map { |v| jsonable(v, depth + 1) }
      when String, Numeric, TrueClass, FalseClass, NilClass then obj
      when Symbol then obj.to_s
      else obj.to_s[0, 500]
      end
    rescue StandardError
      nil
    end
  end
end
