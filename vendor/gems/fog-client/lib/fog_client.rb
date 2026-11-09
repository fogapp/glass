# frozen_string_literal: true

# FogClient: the app-side view of Fog's federation (fog's docs/federation-contract.md).
#
# Fog injects FOG_API_URL and FOG_API_TOKEN into every app it manages. This
# client wraps that surface: which other Fog instances ("peers") the operator
# has exposed to apps, which apps those peers run and where. The point is
# zero-config discovery — a "select a household" list instead of a URL typed
# over Signal.
#
# Two rules this client enforces by construction:
#
#   1. Inert without Fog. No env vars → `available?` is false, `peers` is
#      [], nothing raises. An app using this gem runs identically outside
#      the fog stack — fog is a convenience, never a dependency.
#   2. Never hurt the host app. Short timeouts, every network failure
#      swallowed into an empty answer. Fog being down costs a feature,
#      never a request.
#
# (Named FogClient, not Fog, to stay clear of the classic `fog` cloud gem.)

require "json"
require "net/http"
require "uri"
require_relative "fog_client/version"
require_relative "fog_client/signin"

module FogClient
  DirectoryApp = Struct.new(:app, :title, :url, :contracts, keyword_init: true)
  # name is the addressing key — pass it back to `introduce`, match on it,
  # store it. display_name is the one to put in front of a person: the
  # operator's label for this peer when they set one, the same name
  # otherwise. Showing name in a UI shows a peer by a name its operator may
  # already have replaced.
  Peer = Struct.new(:name, :display_name, :instance_id, :online, :last_seen_at, :apps,
                    keyword_init: true) do
    def online? = !!online
  end
  # A brokered credential: the peer app's URL plus whatever it minted.
  # Credential shape is the granting app's choice — treat it as opaque JSON.
  Introduction = Struct.new(:app, :url, :credential, keyword_init: true)
  # The Trust Bridge: a fog-signed token attesting a connection, plus the
  # sibling app's advertised URL. VouchCheck is the answer to verifying one.
  Vouch = Struct.new(:vouch, :url, keyword_init: true)
  VouchCheck = Struct.new(:ok, :from_instance, :from_name, :app, :from_app, :from_key, keyword_init: true)
  # Can the internet dial this household? The same verdict fog shows its
  # operator on the Federation page: via is "advertised", "domain" or "none";
  # url is the dialable address when there is one; advice is the operator's
  # next step when there is not. reachable? false is a soft state — one
  # reachable side keeps a peering fresh — so treat it as "pause public
  # delivery and say so", never as an error.
  Reachability = Struct.new(:reachable, :url, :via, :tunnel_configured, :tunnel_running, :advice,
                            keyword_init: true) do
    def reachable? = !!reachable
  end
  # A folder fog has mounted into this app's container. kind is "local" or
  # "peer"; peer/share name the source of a peer mount; read_only/hydrated/
  # status/last_synced_at describe its state.
  Mount = Struct.new(:mount, :host_path, :kind, :peer, :share, :read_only, :hydrated,
                     :status, :last_synced_at, keyword_init: true) do
    def peer? = kind == "peer"
  end

  # Default timeouts (seconds). These calls run on the caller's thread —
  # often a web request — so every phase of the HTTP exchange is bounded:
  # without an explicit write_timeout, Net::HTTP would wait 60s on a stalled
  # send. Request-path callers can tighten open/read per call.
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5
  POST_READ_TIMEOUT = 20 # introductions relay across instances
  WRITE_TIMEOUT = 5

  class << self
    def url = presence(ENV["FOG_API_URL"])
    def token = presence(ENV["FOG_API_TOKEN"])

    # True when this process runs under a Fog that injected its API surface.
    # UI should key off this: available → offer the federation shortcuts,
    # absent → the page is exactly what it was before Fog existed.
    def available? = !url.nil? && !token.nil?

    def federation = Federation
    def files = Files

    # One JSON GET against the fog surface. Internal; returns nil on any
    # failure (network, non-2xx, parse) — callers turn nil into empties.
    def get_json(path, open_timeout: nil, read_timeout: nil)
      return nil unless available?
      uri = api_uri(path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout || OPEN_TIMEOUT
      http.read_timeout = read_timeout || READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{token}"
      resp = http.request(req)
      return nil unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    rescue StandardError
      nil
    end

    # One JSON POST, same discipline. Returns the parsed response or nil.
    def post_json(path, payload, open_timeout: nil, read_timeout: nil)
      return nil unless available?
      uri = api_uri(path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout || OPEN_TIMEOUT
      http.read_timeout = read_timeout || POST_READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(payload)
      resp = http.request(req)
      return nil unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    rescue StandardError
      nil
    end

    private

    # URI.join would apply RFC 3986 resolution: an absolute path like
    # /app/v1/... REPLACES any path prefix in FOG_API_URL, so a base of
    # http://fog.lan:8080/api would silently lose its /api. Plain
    # concatenation keeps whatever prefix the operator configured.
    def api_uri(path)
      URI.parse(url.chomp("/") + path)
    end

    def presence(v)
      v.nil? || v.empty? ? nil : v
    end
  end

  module Federation
    # peers is pitched for the request path (render a household list), so a
    # successful answer is cached in-process for a short TTL: a page with
    # three fog-assisted widgets costs one fog round-trip per TTL window,
    # not one per render. Failures are never cached — the next call retries.
    PEERS_CACHE_TTL = 30 # seconds
    @peers_cache = nil # [monotonic_fetched_at, cache_key, result]
    @peers_mutex = Mutex.new

    # Ask fog to broker a credential with a peer's app (fog-federation/1).
    # The result lands in the SAME shape the app's manual remote-connection
    # form would produce — an introduction is a pre-filled form, never a
    # side door. Returns nil when refused, unreachable, or outside fog.
    def self.introduce(peer:, app:, public_key: nil, open_timeout: nil, read_timeout: nil)
      body = { peer: peer, app: app }
      body[:publicKey] = public_key if public_key
      data = FogClient.post_json("/app/v1/federation/introductions", body,
                                 open_timeout: open_timeout, read_timeout: read_timeout)
      return nil unless data
      Introduction.new(app: data["app"], url: data["url"], credential: data["credential"])
    end

    # The Trust Bridge: ask fog to vouch for a connection to a sibling app on
    # a paired peer. fog signs a short-lived attestation; carry it to the
    # sibling, which verifies it through its own fog. nil when refused,
    # unreachable, or outside fog.
    def self.vouch(peer:, app:, public_key: nil, open_timeout: nil, read_timeout: nil)
      body = { peer: peer, app: app }
      body[:publicKey] = public_key if public_key
      data = FogClient.post_json("/app/v1/federation/vouch", body,
                                 open_timeout: open_timeout, read_timeout: read_timeout)
      return nil unless data
      Vouch.new(vouch: data["vouch"], url: data["url"])
    end

    # Verify a vouch a sibling presented, through our own fog. Returns a
    # VouchCheck (ok?, and when ok who it is from). nil outside fog.
    def self.verify_vouch(token, open_timeout: nil, read_timeout: nil)
      data = FogClient.post_json("/app/v1/federation/vouch/verify", { vouch: token },
                                 open_timeout: open_timeout, read_timeout: read_timeout)
      return nil unless data
      from = data["from"] || {}
      VouchCheck.new(ok: data["ok"] == true, from_instance: from["instance"], from_name: from["name"],
                     app: data["app"], from_app: data["fromApp"], from_key: data["fromKey"])
    end

    # Whether this household is dialable from the internet, as fog itself
    # judges it — so an app can say so honestly in its own UI and pause
    # public delivery rather than burn attempts. nil when fog is unreachable
    # or outside fog; uncached, since the answer changes when the operator
    # acts on the advice.
    def self.reachability(open_timeout: nil, read_timeout: nil)
      data = FogClient.get_json("/app/v1/federation/reachability",
                                open_timeout: open_timeout, read_timeout: read_timeout)
      return nil unless data
      tunnel = data["tunnel"] || {}
      Reachability.new(reachable: data["reachable"] == true, url: data["url"], via: data["via"],
                       tunnel_configured: tunnel["configured"] == true,
                       tunnel_running: tunnel["running"] == true, advice: data["advice"])
    end

    # The federated peers this app is allowed to see, with each peer's
    # exposed apps. Empty when unfederated, when fog is unreachable, or
    # when running outside fog entirely.
    #
    #   fresh: true   skip the cache for this call (still refills it)
    #   ttl:          seconds a cached answer stays good (default 30)
    #   open_timeout:/read_timeout: per-call HTTP bounds for tight paths
    def self.peers(fresh: false, ttl: PEERS_CACHE_TTL,
                   open_timeout: nil, read_timeout: nil)
      key = [FogClient.url, FogClient.token]
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      unless fresh
        cached = @peers_mutex.synchronize { @peers_cache }
        return cached[2] if cached && cached[1] == key && now - cached[0] < ttl
      end
      result = fetch_peers(open_timeout: open_timeout, read_timeout: read_timeout)
      unless result.nil?
        @peers_mutex.synchronize { @peers_cache = [now, key, result] }
        return result
      end
      []
    end

    # The uncached fetch: nil on any failure (so the caller knows not to
    # cache an empty answer born from an outage), an array otherwise.
    def self.fetch_peers(open_timeout: nil, read_timeout: nil)
      data = FogClient.get_json("/app/v1/federation/peers",
                                open_timeout: open_timeout, read_timeout: read_timeout)
      return nil unless data
      Array(data["peers"]).map do |p|
        Peer.new(
          name: p["name"],
          # A fogd older than displayName still answers with name alone, and
          # a UI that reads display_name must not go blank against one.
          display_name: p["displayName"].to_s.empty? ? p["name"] : p["displayName"],
          instance_id: p["instanceId"],
          online: p["online"],
          last_seen_at: p["lastSeenAt"],
          apps: Array(p["apps"]).map do |a|
            DirectoryApp.new(app: a["app"], title: a["title"], url: a["url"],
                             contracts: Array(a["contracts"]))
          end
        )
      end
    end
    private_class_method :fetch_peers
  end

  module Files
    # The folders fog has mounted into this app's container — its own storage
    # and any peer shares — with each one's kind, source and sync state.
    # Empty when unfederated, when fog is unreachable, or outside fog. Any app
    # that binds peer folders can read this instead of hand-rolling the call.
    def self.mounts(open_timeout: nil, read_timeout: nil)
      data = FogClient.get_json("/app/v1/files/mounts",
                                open_timeout: open_timeout, read_timeout: read_timeout)
      return [] unless data

      Array(data["mounts"]).map do |m|
        Mount.new(mount: m["mount"], host_path: m["hostPath"], kind: m["kind"],
                  peer: m["peer"], share: m["share"], read_only: m["readOnly"],
                  hydrated: m["hydrated"], status: m["status"], last_synced_at: m["lastSyncedAt"])
      end
    end
  end
end
