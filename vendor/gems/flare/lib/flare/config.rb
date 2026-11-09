# frozen_string_literal: true

require "uri"

module Flare
  class Config
    # DSN shape (minted by Fog): http://<key>@host.docker.internal:8080/ingest/<app_id>
    # Sentry DSN semantics: the last path segment is the project id, anything
    # before it is a path prefix, and the derived ingest endpoint is
    # <scheme>://<host>/<prefix>/api/<project>/envelope/.
    ParsedDSN = Struct.new(:key, :endpoint)

    attr_accessor :dsn, :environment, :app_root, :logger,
                  :queue_size, :open_timeout, :read_timeout, :context_lines,
                  :rails_filters, :sender
    attr_writer :release

    # Matched against param/context keys (case-insensitive) in addition to
    # whatever Rails' own filter_parameters contribute via the railtie.
    FILTER_KEYS = /password|passwd|secret|token|api_key|apikey|access_key|auth|credential|cookie|session/i
    FILTERED = "[FILTERED]"

    def initialize
      @dsn = ENV["FLARE_DSN"]
      @environment = default_environment
      @app_root = default_root
      @queue_size = 100
      @open_timeout = 3
      @read_timeout = 5
      @context_lines = 3
      @rails_filters = []
      @release = nil
      @logger = nil
    end

    def enabled?
      !parsed_dsn.nil?
    end

    def parsed_dsn
      return @parsed_dsn if defined?(@parsed_dsn)
      @parsed_dsn = parse_dsn(dsn)
    end

    # Release identity, most reliable source first: the env Fog's builds
    # inject, then the REVISION file baked into the image.
    def release
      return @release if @release
      return ENV["GIT_SHA"] if ENV["GIT_SHA"].to_s != ""
      return ENV["GIT_REV"] if ENV["GIT_REV"].to_s != ""
      rev_file = File.join(app_root, "REVISION")
      @release = File.read(rev_file).strip if File.exist?(rev_file)
      @release || ""
    rescue StandardError
      ""
    end

    # Deep-scrub a params/context hash: any key matching the built-in
    # patterns or Rails' filter_parameters is replaced. Values are already
    # whatever the caller serialized; only keys drive filtering, same as
    # Rails' own log filtering.
    def scrub(obj)
      case obj
      when Hash
        obj.to_h { |k, v| [k, filtered_key?(k) ? FILTERED : scrub(v)] }
      when Array
        obj.map { |v| scrub(v) }
      else
        obj
      end
    end

    private

    def filtered_key?(key)
      k = key.to_s
      return true if FILTER_KEYS.match?(k)
      rails_filters.any? do |f|
        case f
        when Regexp then f.match?(k)
        when String, Symbol then k.downcase.include?(f.to_s.downcase)
        else false # proc filters transform values in Rails; out of scope here
        end
      end
    end

    def parse_dsn(raw)
      return nil if raw.nil? || raw.empty?
      u = URI.parse(raw)
      key = u.user
      project = File.basename(u.path.to_s)
      return nil unless key && !key.empty? && project.match?(/\A\d+\z/)
      prefix = File.dirname(u.path)
      prefix = "" if prefix == "/" || prefix == "."
      endpoint = "#{u.scheme}://#{u.host}:#{u.port}#{prefix}/api/#{project}/envelope/"
      ParsedDSN.new(key, endpoint)
    rescue URI::Error
      nil
    end

    def default_environment
      if defined?(Rails) && Rails.respond_to?(:env)
        Rails.env.to_s
      else
        ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "production"
      end
    end

    def default_root
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s
      else
        Dir.pwd
      end
    end
  end
end
