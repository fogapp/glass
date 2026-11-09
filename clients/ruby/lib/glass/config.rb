# frozen_string_literal: true

require "uri"
require "ipaddr"
require_relative "origin"

module Glass
  # Everything the agent can be told, and the directives the server tells it.
  #
  # Two values make it live (GLASS_URL, GLASS_API_KEY); everything else has a
  # default that fits a fog-managed Rails app. Directives arrive in every
  # ingest reply (docs/ingest-protocol.md) and override the runtime knobs —
  # sampling, profiling, log level, identity — without a redeploy. A local
  # `enabled[:feature] = false` is a kill switch that wins over any directive.
  class Config
    # Matched against attribute/payload keys (case-insensitive), on top of
    # whatever the app's own filter_parameters contribute via the railtie.
    FILTER_KEYS = /password|passwd|secret|token(?!s)|api_key|apikey|access_key|auth|credential|cookie|session(?:_?id)?$/i
    FILTERED = "[FILTERED]"

    FEATURES = %i[requests jobs sql views cache http errors runtime profiling logs events].freeze
    IDENTITIES = %w[anonymous pseudonymous named].freeze
    LOG_LEVELS = { "debug" => 0, "info" => 1, "warn" => 2, "error" => 3, "fatal" => 4, "off" => 99 }.freeze

    attr_accessor :url, :api_key, :flush_interval, :queue_size, :ignore_paths, :user, :user_name,
                  :vpn_ranges, :propagate_to, :logger, :app_root, :rails_filters, :sender, :open_timeout, :read_timeout,
                  :profile_window, :autostart
    # false: requests and pageviews carry their route template and never the
    # concrete path, for an app whose URLs name what it must not send.
    # Local only; no directive turns it back on.
    attr_accessor :record_paths
    attr_writer :release, :process_kind
    # Per-feature kill switches: `config.enabled[:profiling] = false`.
    attr_reader :enabled
    # Directive-backed runtime settings (readers; writers validate).
    attr_reader :trace_sample_rate, :profiling, :profile_hz, :log_level, :browser, :identity

    def initialize
      @url = ENV["GLASS_URL"]
      @api_key = ENV["GLASS_API_KEY"]
      @process_kind = ENV["GLASS_PROCESS"]
      @flush_interval = 10
      @queue_size = 5_000
      # /up is fog's health probe; /ingest is Glass's own ingest route, so an
      # app that is Glass never traces its own reports.
      @ignore_paths = ["/up", "/ingest"]
      @user = DEFAULT_USER
      @user_name = DEFAULT_USER_NAME
      @vpn_ranges = []
      # Host suffixes that are ours beyond private addresses, bare names and
      # NetHttp::INTERNAL_SUFFIXES: "example.net" lets app.example.net
      # continue the trace.
      @propagate_to = []
      @logger = nil
      @app_root = default_root
      @rails_filters = []
      @sender = nil
      @open_timeout = 3
      @read_timeout = 5
      @profile_window = 60
      @autostart = nil
      @release = nil
      @enabled = Hash.new(true)
      @trace_sample_rate = 0.1
      @profiling = true
      @profile_hz = 100
      @log_level = "info"
      @browser = false
      @identity = "pseudonymous"
      @record_paths = true
    end

    def enabled?
      !url.to_s.empty? && !api_key.to_s.empty?
    end

    def feature?(name)
      @enabled[name]
    end

    def endpoint
      "#{url.to_s.chomp('/')}/ingest/v1/batch"
    end

    # Release identity, most reliable source first: the env fog's builds
    # inject, then the REVISION file baked into the image. Computed once —
    # it cannot change within a process.
    def release
      @release ||= compute_release
    end

    # `web` unless this looks like a job runner. Not memoized: Solid Queue's
    # forked processes rename themselves ($0 = "solid-queue-worker…") a
    # moment after the fork, and the answer is only needed once per flush.
    def process_kind
      @process_kind || detect_process_kind
    end

    def ignore_path?(path)
      return false if path.nil?
      @ignore_paths.any? { |prefix| path.start_with?(prefix) }
    end

    # --- directives -------------------------------------------------------

    def trace_sample_rate=(value)
      @trace_sample_rate = value.to_f.clamp(0.0, 1.0) if value.is_a?(Numeric)
    end

    def profiling=(value)
      @profiling = (value == true)
    end

    def profile_hz=(value)
      @profile_hz = value.to_i.clamp(10, 1_000) if value.is_a?(Numeric)
    end

    def log_level=(value)
      @log_level = value.to_s if LOG_LEVELS.key?(value.to_s)
    end

    def log_threshold
      LOG_LEVELS.fetch(@log_level, 1)
    end

    def browser=(value)
      @browser = (value == true)
    end

    def identity=(value)
      @identity = value.to_s if IDENTITIES.include?(value.to_s)
    end

    # Apply a `directives` object from an ingest reply. Unknown keys are
    # ignored; known keys with junk values keep their previous setting.
    # Returns the `profile_now` request (a Hash) when one was sent.
    def apply_directives(directives)
      return nil unless directives.is_a?(Hash)
      self.trace_sample_rate = directives["trace_sample_rate"] if directives.key?("trace_sample_rate")
      self.profiling = directives["profiling"] if directives.key?("profiling")
      self.profile_hz = directives["profile_hz"] if directives.key?("profile_hz")
      self.log_level = directives["log_level"] if directives.key?("log_level")
      self.browser = directives["browser"] if directives.key?("browser")
      self.identity = directives["identity"] if directives.key?("identity")
      now = directives["profile_now"]
      now.is_a?(Hash) && now["id"] ? now : nil
    end

    # Profiling is on when the local switch and the directive agree.
    def profiling_active?
      feature?(:profiling) && @profiling
    end

    # Browser analytics likewise: the `browser` directive plus the local
    # switch. Off means no injection, an empty script and beacons dropped.
    def browser_active?
      feature?(:browser) && @browser
    end

    # --- scrubbing --------------------------------------------------------

    # Deep-scrub a hash: any key matching the built-in patterns or Rails'
    # filter_parameters is replaced. Only keys drive filtering, same as
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

    # Configured VPN ranges as IPAddr objects, re-parsed when the array
    # changes. Junk entries are skipped rather than raised.
    def vpn_networks
      raw = Array(@vpn_ranges)
      return @vpn_networks if defined?(@vpn_networks) && @vpn_networks_raw == raw
      @vpn_networks_raw = raw.dup
      @vpn_networks = [Origin::CGNAT] + raw.filter_map { |r| IPAddr.new(r.to_s) rescue nil }
    end

    private

    DEFAULT_USER = lambda do
      if defined?(::Current) && ::Current.respond_to?(:user)
        user = ::Current.user
        user.respond_to?(:id) ? user.id : nil
      end
    end

    DEFAULT_USER_NAME = lambda do
      if defined?(::Current) && ::Current.respond_to?(:user)
        user = ::Current.user
        user.respond_to?(:name) ? user.name : nil
      end
    end

    def compute_release
      return ENV["GIT_SHA"] if ENV["GIT_SHA"].to_s != ""
      return ENV["GIT_REV"] if ENV["GIT_REV"].to_s != ""
      rev_file = File.join(app_root, "REVISION")
      return File.read(rev_file).strip if File.exist?(rev_file)
      ""
    rescue StandardError
      ""
    end

    def detect_process_kind
      prog = $PROGRAM_NAME.to_s
      return "worker" if File.basename(prog) == "jobs"
      return "worker" if prog.start_with?("solid-queue-")
      return "worker" if defined?(::Sidekiq) && ::Sidekiq.respond_to?(:server?) && ::Sidekiq.server?
      if defined?(::Rake) && ::Rake.respond_to?(:application)
        tasks = ::Rake.application.top_level_tasks rescue []
        return "worker" if tasks.any? { |t| t.to_s.match?(/jobs|solid_queue|sidekiq/i) }
      end
      "web"
    rescue StandardError
      "web"
    end

    def default_root
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      else
        Dir.pwd
      end
    end
  end
end
