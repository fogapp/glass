# frozen_string_literal: true

require "ipaddr"
require_relative "bounded_cache"

module Glass
  # Where a request came from, as a network class — `lan`, `vpn`, `tunnel`
  # or `public` — decided from the client address and then forgotten. The
  # address itself is never sent.
  #
  # The chain is REMOTE_ADDR plus X-Forwarded-For, walked from the nearest
  # hop outwards: the first address that is not private decides (a VPN
  # range says vpn, anything else says public). A chain that is private all
  # the way out is the LAN. Walking from the near end means a client on the
  # public internet cannot claim to be on the LAN by sending its own
  # X-Forwarded-For — the proxy appends the real address after it.
  module Origin
    CACHE_MAX = 1_000
    # Tailscale / CGNAT: the range every home VPN hands out. A visitor from
    # it is on the VPN; a sibling over it is ours (NetHttp).
    CGNAT = IPAddr.new("100.64.0.0/10")
    @cache = BoundedCache.new(CACHE_MAX)

    class << self
      def classify(env, vpn_networks)
        classify_with_address(env, vpn_networks).last
      end

      # [deciding address, class]. The address is the hop that decided the
      # class (or the outermost hop of an all-private chain); it is used for
      # the anonymous visitor hash and never stored.
      def classify_with_address(env, vpn_networks)
        tunnel = env["HTTP_CF_CONNECTING_IP"] || env["HTTP_CF_RAY"]
        chain = []
        forwarded = env["HTTP_X_FORWARDED_FOR"]
        forwarded.split(",").each { |a| chain << a.strip } if forwarded
        remote = env["REMOTE_ADDR"]
        chain << remote.strip if remote
        cf = env["HTTP_CF_CONNECTING_IP"]
        return [cf.to_s.strip, "tunnel"] if tunnel && cf
        return [chain.first, tunnel ? "tunnel" : nil] if chain.empty? || tunnel
        chain.reverse_each do |address|
          case kind(address, vpn_networks)
          when :vpn then return [address, "vpn"]
          when :public then return [address, "public"]
          end
        end
        [chain.first, "lan"]
      rescue StandardError
        [nil, nil]
      end

      # :private, :vpn or :public; :skip when it is not an address at all.
      # Memoized per address string: a home fleet sees a handful of
      # distinct addresses, and IPAddr parsing is the only cost.
      def kind(address, vpn_networks)
        @cache.fetch(address) { compute(address, vpn_networks) }
      end

      def reset!
        @cache.clear
      end

      private

      def compute(address, vpn_networks)
        ip = IPAddr.new(address)
        ip = ip.native if ip.ipv4_mapped?
        return :vpn if vpn_networks.any? { |net| net.include?(ip) rescue false }
        return :private if ip.loopback? || ip.private? || ip.link_local?
        :public
      rescue IPAddr::Error, ArgumentError
        :skip # unparseable (a unix socket, junk): does not decide
      end
    end
  end
end
