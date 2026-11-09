# frozen_string_literal: true

require "net/http"
require_relative "bounded_cache"
require_relative "origin"

module Glass
  # Outbound HTTP as `http` spans, and trace propagation to siblings only.
  # `traceparent` goes to a host that is ours (docs/ingest-protocol.md,
  # rule 8 for an agent): an address that is not public by the origin
  # rule (private, CGNAT, the configured VPN ranges), a bare hostname (fog's
  # Docker DNS names: http://glass, http://hook), or a name under
  # INTERNAL_SUFFIXES or the configured `propagate_to` — never to the public
  # internet, where the header would leak trace ids to third parties for no
  # benefit. The conformance kit's origin.json holds every client to it.
  module NetHttp
    MAX_PATH = 200
    # Names that only resolve inside a home network: a router's `.lan`,
    # mDNS's `.local`, ICANN's private-use `.internal` (host.docker.internal).
    INTERNAL_SUFFIXES = %w[lan local internal].freeze
    @propagate = BoundedCache.new(256)

    def self.install!
      return if @installed
      @installed = true
      ::Net::HTTP.prepend(Patch)
    end

    # Asked on every outbound request: remembered per host.
    def self.propagate?(host)
      return false if host.nil? || host.empty?
      @propagate.fetch(host) { ours?(host, Glass.config) }
    end

    def self.reset!
      @propagate.clear
    end

    def self.ours?(host, config)
      name = host.downcase.delete_prefix("[").delete_suffix("]")
      return false if name.empty?
      case Origin.kind(name, config.vpn_networks)
      when :private, :vpn then return true
      when :public then return false
      end
      return true unless name.include?(".")
      (INTERNAL_SUFFIXES + Array(config.propagate_to)).any? do |suffix|
        want = suffix.to_s.downcase.delete_prefix(".")
        !want.empty? && (name == want || name.end_with?(".#{want}"))
      end
    end
    private_class_method :ours?

    module Patch
      # Net::HTTP#request re-enters itself through #start when the
      # connection is not open yet; only the started call is measured, so
      # one request is one span.
      def request(req, body = nil, &block)
        txn = started? && !Thread.current[:glass_agent] && Glass.enabled? ? Glass::Tracer.current : nil
        return super unless txn && Glass.config.feature?(:http)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        span = nil
        begin
          host = address.to_s
          name = "#{req.method} #{host}"
          span = txn.start_span("http", name, "#{req.method} #{host}#{req.path.to_s.split('?', 2).first.to_s[0, MAX_PATH]}", start)
          if Glass::NetHttp.propagate?(host) && !req["traceparent"]
            req["traceparent"] = "00-#{txn.trace_id}-#{txn.span_hex(span)}-01"
          end
        rescue StandardError => e
          Glass.error("http", e)
        end
        failed = nil
        response = nil
        begin
          response = super
        rescue Exception => e
          failed = e
          raise
        ensure
          begin
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            dur = (now - start) * 1000.0
            txn.ext_ms += dur
            txn.ext_n += 1
            if span
              txn.finish_span(span, now, error: failed || (response && response.code.to_i >= 500))
              span.attrs = { "status" => response.code.to_i } if response
            end
          rescue StandardError => e
            Glass.error("http", e)
          end
        end
      end
    end
  end
end
