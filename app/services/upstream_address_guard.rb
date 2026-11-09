# typed: strict
# frozen_string_literal: true

require "ipaddr"
require "resolv"

# Refuses to fetch anything on the machine's own network.
#
# Part of the fleet's shared outbound-HTTP kit (with UpstreamHttpClient and
# UpstreamCircuitBreaker), kept identical across the sibling apps. Every
# client Glass has today talks to infrastructure the household runs — fog's
# MCP surface and event stream, the ntfy relay — and opts out (below). The
# guard is the default for whatever comes next that fetches a URL Glass was
# handed rather than one the operator configured: a webhook target, a link a
# reporting app sent. Fetching such a URL — and whatever it redirects to — is
# the classic shape of a server-side request forgery: the attacker never needs
# credentials, only a URL Glass will dutifully GET from inside the network the
# browser can't reach.
#
# The addresses below are the ones with nothing legitimate to say to such a
# fetch. 169.254.169.254 is the cloud metadata endpoint on every major
# provider; 127/8 and the RFC 1918 ranges are the fog network, the database,
# the sibling apps, and the router's admin page.
#
# THIS IS NOT A BAN ON PRIVATE ADDRESSES GENERALLY. fogd and ntfy are
# supposed to be on private addresses, and a household points Glass at them
# in Settings (CLAUDE.md: configuration belongs in the UI) or fog injects
# them. Those clients opt out explicitly through allow_private_addresses?
# (HouseholdUpstream, reviewed once for all of them), which is why this is a
# per-caller decision rather than a global rule.
#
# check! returns the vetted address, and UpstreamHttpClient pins the
# connection to it (Net::HTTP#ipaddr=, with the original host kept for
# Host/SNI/verification). That closes the classic rebinding gap — resolve
# here, resolve again inside Net::HTTP, get a different answer — because the
# second resolution never happens: the socket opens to the exact address this
# module approved.
module UpstreamAddressGuard
  extend T::Sig

  class Blocked < StandardError; end

  ALLOWED_SCHEMES = T.let(%w[http https].freeze, T::Array[String])

  # Written out rather than leaning on IPAddr#private?, which covers RFC 1918
  # and not the several other ranges that are just as much "inside".
  BLOCKED_RANGES = T.let([
    "0.0.0.0/8",        # this network
    "10.0.0.0/8",       # RFC 1918
    "127.0.0.0/8",      # loopback
    "169.254.0.0/16",   # link-local, incl. the cloud metadata endpoint
    "172.16.0.0/12",    # RFC 1918
    "192.0.0.0/24",     # IETF protocol assignments
    "192.168.0.0/16",   # RFC 1918
    "198.18.0.0/15",    # benchmarking
    "224.0.0.0/4",      # multicast
    "240.0.0.0/4",      # reserved
    "::/128",           # unspecified
    "::1/128",          # loopback
    "fc00::/7",         # unique local
    "fe80::/10",        # link-local
    "ff00::/8"          # multicast
  ].map { |range| IPAddr.new(range) }.freeze, T::Array[IPAddr])

  # Raises rather than returning false: every caller's only sensible response
  # is to stop, and a predicate invites somebody to forget to check it.
  #
  # Returns the vetted address the caller should connect to (IPv4 preferred,
  # since a host with broken IPv6 routing is common and a pinned AAAA would
  # turn it into a hard failure). Callers that can pin — UpstreamHttpClient
  # can — must use it; connecting by name would resolve a second time and
  # reopen the rebinding window this return value exists to close.
  sig { params(url: String, service_name: String).returns(String) }
  def self.check!(url, service_name:)
    uri = URI.parse(url)
    scheme = uri.scheme.to_s.downcase
    unless ALLOWED_SCHEMES.include?(scheme)
      raise Blocked, "#{service_name}: #{scheme.presence || 'that'} is not a scheme Glass will fetch"
    end

    host = uri.host.to_s
    raise Blocked, "#{service_name}: that URL has no host" if host.blank?

    addresses = addresses_for(host)
    # Fail closed. A name that cannot be resolved cannot be vetted, and
    # letting it through hands the decision to whatever resolver answers the
    # actual connect — a resolver an attacker can slow down or answer late.
    if addresses.empty?
      raise Blocked, "#{service_name}: #{host} did not resolve — Glass only fetches addresses " \
                     "it can vet"
    end

    blocked = addresses.find { |address| blocked?(address) }
    unless blocked.nil?
      raise Blocked, "#{service_name}: #{host} resolves to #{blocked}, which is on this machine's " \
                     "own network — Glass only fetches from the public internet"
    end

    T.must(addresses.find { |address| IPAddr.new(address).ipv4? } || addresses.first)
  rescue URI::InvalidURIError
    raise Blocked, "#{service_name}: that isn't a URL Glass can parse"
  end

  # How long a resolution is reused, and how many are held.
  #
  # This is the difference between a guard that costs nothing and one that puts
  # a DNS round trip in front of every fetch — Glass asks the same few dozen
  # hosts over and over, so almost every lookup is one it just did. Kept short
  # because it also widens the rebinding window described above, and kept
  # process-local rather than in Rails.cache because in production that store
  # is backed by the database, which would trade a DNS round trip for a SQL one.
  RESOLUTION_TTL = T.let(60, Integer)
  # How long the last *successful* resolution may keep serving once the
  # resolver stops answering. A nameserver blip is not evidence a host moved:
  # production spent an evening raising "huggingface.co did not resolve" for
  # a host it resolves all day, because a transient resolver failure and a
  # genuinely unknown name both came back as []. Serving the last vetted
  # answer for a bounded window keeps that distinction — the addresses were
  # vetted when fresh and check! re-vets them against BLOCKED_RANGES on every
  # call, so nothing unvetted slips through, and an attacker who controls DNS
  # gains nothing from us preferring an *older* answer. A host never resolved,
  # or dark past the window, still fails closed.
  STALE_RESOLUTION_TTL = T.let(60 * 60, Integer)
  MAX_CACHED_HOSTS = 512

  @resolutions = T.let({}, T::Hash[String, [ Float, T::Array[String] ]])
  @lock = T.let(Mutex.new, Mutex)

  sig { params(host: String).returns(T::Array[String]) }
  def self.addresses_for(host)
    literal = IPAddr.new(host)
    [ literal.to_s ]
  rescue IPAddr::Error
    cached_resolution(host)
  end

  sig { params(host: String).returns(T::Array[String]) }
  def self.cached_resolution(host)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
    @lock.synchronize do
      cached = @resolutions[host]
      return cached[1] if cached && now - cached[0] < RESOLUTION_TTL
    end

    # DNS strictly outside the lock: holding a process-wide mutex across a
    # network round trip serialized every Puma and worker thread behind one
    # sulky nameserver — the same hang class the circuit breaker exists to
    # prevent one layer down. Two threads missing the same host at once pay
    # a duplicate lookup; that is far cheaper than a convoy.
    addresses = resolve(host)

    @lock.synchronize do
      if addresses.empty?
        # Stale-serve (see STALE_RESOLUTION_TTL). The timestamp is not
        # refreshed, so the window runs from the last real answer — a
        # resolver that stays dark eventually fails closed again.
        stale = @resolutions[host]
        return stale[1] if stale && now - stale[0] < STALE_RESOLUTION_TTL

        return []
      end

      # Wholesale rather than LRU eviction: the working set is a household's
      # source list, so the cache is either comfortably under the cap or
      # something unusual is happening and starting over is the right answer.
      @resolutions.clear if @resolutions.size >= MAX_CACHED_HOSTS
      @resolutions[host] = [ now, addresses ]
    end
    addresses
  end

  # /etc/hosts first, then DNS with a short timeout. The hosts file matters on
  # bare-host deploys where a name only exists locally; the timeout matters
  # because a fetch must not be able to hang on a nameserver that has stopped
  # answering — that is the same failure the circuit breaker exists to prevent
  # one layer down. (Not Addrinfo.getaddrinfo, which has no timeout knob at
  # all.) Failure returns [] and check! treats that as blocked.
  sig { params(host: String).returns(T::Array[String]) }
  def self.resolve(host)
    from_hosts_file =
      begin
        Resolv::Hosts.new.getaddresses(host).map(&:to_s)
      rescue StandardError
        []
      end
    return from_hosts_file if from_hosts_file.any?

    resolver = Resolv::DNS.new
    resolver.timeouts = [ 1, 2 ]
    resolver.getaddresses(host).map(&:to_s)
  rescue StandardError
    []
  ensure
    resolver&.close
  end

  sig { params(address: String).returns(T::Boolean) }
  def self.blocked?(address)
    parsed = IPAddr.new(address)
    BLOCKED_RANGES.any? { |range| range.include?(parsed) }
  rescue IPAddr::Error
    false
  end

  private_class_method :addresses_for, :cached_resolution, :resolve, :blocked?
end
