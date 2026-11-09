# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require "zlib"
require_relative "bounded_cache"
require_relative "origin"

module Glass
  # The browser side of the agent: serves glass.js on the
  # app's own origin, injects its tag into HTML, and turns the beacons it
  # posts to /_glass/b into `page` records — stamping what only the server
  # knows (origin, user agent, visitor, user) and validating the rest, so a
  # page can report what a person did but never who they are, where they
  # are, or anything they typed.
  module Relay
    SCRIPT_PATH = File.expand_path("assets/glass.js", __dir__)
    SCRIPT_ROUTE = "/_glass/glass.js"
    BEACON_ROUTE = "/_glass/b"
    TAG = %(<script defer src="/_glass/glass.js"></script>)
    MAX_BODY = 64 * 1024
    MAX_EVENTS = 100
    UNSEEN_QUOTA = 50
    KINDS = %w[pageview click submit vital custom error].freeze
    VITALS = %w[lcp inp cls ttfb fcp].freeze
    VISIT = /\Av_[0-9a-f]{12}\z/
    MAX_PROPS = 32
    MAX_PROP_VALUE = 200
    NO_BODY = [].freeze

    class << self
      # --- glass.js -----------------------------------------------------------

      def script
        @script ||= begin
          raw = File.binread(SCRIPT_PATH)
          etag = %("glass-#{VERSION}-#{Digest::SHA256.hexdigest(raw)[0, 16]}")
          { raw: raw, gzip: Zlib.gzip(raw), etag: etag }
        end
      end

      # What answers for glass.js while the browser directive is off: an
      # empty script nobody caches, so the real one arrives the moment it is
      # turned on.
      def idle_script
        [200, { "content-type" => "application/javascript; charset=utf-8", "cache-control" => "no-store", "content-length" => "0" }, NO_BODY]
      end

      def serve_script(env)
        s = script
        headers = {
          "content-type" => "application/javascript; charset=utf-8",
          "etag" => s[:etag],
          "cache-control" => "public, max-age=86400",
          "vary" => "Accept-Encoding"
        }
        if_none = env["HTTP_IF_NONE_MATCH"].to_s
        return [304, headers, NO_BODY] if if_none.split(",").any? { |t| t.strip.delete_prefix("W/") == s[:etag] }
        if env["HTTP_ACCEPT_ENCODING"].to_s.match?(/\bgzip\b/)
          headers["content-encoding"] = "gzip"
          headers["content-length"] = s[:gzip].bytesize.to_s
          [200, headers, [s[:gzip]]]
        else
          headers["content-length"] = s[:raw].bytesize.to_s
          [200, headers, [s[:raw]]]
        end
      end

      # --- beacons ----------------------------------------------------------------

      # Always a bare status: a page learns nothing from the relay.
      def beacon(env, config)
        return [400, {}, NO_BODY] unless same_origin?(env)
        type = env["CONTENT_TYPE"].to_s
        return [400, {}, NO_BODY] unless type.empty? || type.start_with?("application/json", "text/plain")
        input = env["rack.input"]
        raw = input ? input.read(MAX_BODY + 1).to_s : ""
        return [413, {}, NO_BODY] if raw.bytesize > MAX_BODY
        doc = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end
        return [400, {}, NO_BODY] unless doc.is_a?(Hash)
        visit = doc["visit"]
        events = doc["events"]
        return [400, {}, NO_BODY] unless visit.is_a?(String) && VISIT.match?(visit) && events.is_a?(Array)
        return [400, {}, NO_BODY] if events.size > MAX_EVENTS
        relay(env, config, visit, doc, events)
        [204, {}, NO_BODY]
      rescue StandardError => e
        Glass.error("beacon", e)
        [204, {}, NO_BODY]
      end

      def same_origin?(env)
        host = env["HTTP_HOST"].to_s.downcase
        origin = env["HTTP_ORIGIN"] || env["HTTP_REFERER"]
        return true if origin.nil? || origin.empty?
        uri = URI.parse(origin)
        return false unless uri.host
        h = uri.host.downcase
        h += ":#{uri.port}" if uri.port && uri.port != uri.default_port
        h == host || h == host.split(":").first
      rescue URI::Error
        false
      end

      def relay(env, config, visit, doc, events)
        entry = Visits.for_beacon(visit, events.size)
        return unless entry # over the unseen quota: dropped silently
        address, origin = Origin.classify_with_address(env, config.vpn_networks)
        ua = UserAgent.parse(env["HTTP_USER_AGENT"])
        screen = doc["screen"]
        ua = ua.merge("screen" => screen) if screen.is_a?(String) && screen.match?(/\A\d{1,5}x\d{1,5}\z/)
        lang = doc["lang"].is_a?(String) ? doc["lang"][0, 35] : nil
        visitor = entry[:keyed] || anonymous_visitor(config, address, env["HTTP_USER_AGENT"])
        now = Time.now.to_f
        first_ref = false
        events.each do |ev|
          rec = record(ev, now, config)
          next unless rec
          rec[:visit] = visit
          rec[:visitor] = visitor
          rec[:user] = entry[:user] if entry[:user]
          rec[:ua] = ua
          rec[:lang] = lang if lang
          rec[:origin] = origin if origin
          if rec[:ref]
            rec.delete(:ref) if first_ref
            first_ref = true
          end
          Glass.transport.push(:page, rec)
        end
      end

      # One browser event → one `page` record, or nil. Only known shapes
      # survive; anything with a query string loses it.
      def record(ev, now, config)
        return nil unless ev.is_a?(Hash)
        kind = ev["kind"]
        return nil unless KINDS.include?(kind)
        rec = { t: "page", ts: timestamp(ev["ts"], now), kind: kind }
        path = str(ev["path"], 2_000)
        rec[:path] = path.split("?", 2).first.split("#", 2).first if path && config.record_paths
        route = str(ev["route"], 500)
        rec[:route] = route if route
        case kind
        when "pageview"
          title = str(ev["title"], 200)
          rec[:title] = title if title
          ref = str(ev["ref"], 2_000)
          rec[:ref] = ref.split("?", 2).first if ref
        when "click", "submit"
          name = str(ev["name"], 200)
          rec[:name] = name if name
          el = element(ev["el"])
          rec[:el] = el if el
          props = props(ev["props"], config)
          rec[:props] = props if props
        when "vital"
          vitals = vitals(ev["vitals"])
          return nil unless vitals
          rec[:vitals] = vitals
        when "custom", "error"
          name = str(ev["name"], 200)
          return nil unless name
          rec[:name] = name
          props = props(ev["props"], config)
          rec[:props] = props if props
        end
        rec
      end

      # A browser clock a day behind or minutes ahead is a broken clock;
      # the record is stamped on arrival instead.
      def timestamp(value, now)
        return now unless value.is_a?(Numeric) && value.to_f.finite?
        t = value.to_f
        t.between?(now - 86_400, now + 300) ? t : now
      end

      def str(value, max)
        return nil unless value.is_a?(String)
        v = value.delete("\u0000")
        return nil if v.empty?
        v.size > max ? v[0, max] : v
      end

      def element(el)
        return nil unless el.is_a?(Hash)
        out = {}
        %w[tag role sel].each do |k|
          v = str(el[k], 200)
          out[k] = v if v
        end
        href = str(el["href"], 2_000)
        out["href"] = href.split("?", 2).first.split("#", 2).first if href && href.start_with?("/")
        out.empty? ? nil : out
      end

      def vitals(v)
        return nil unless v.is_a?(Hash)
        out = {}
        VITALS.each do |k|
          x = v[k]
          out[k] = x if x.is_a?(Numeric) && x.to_f.finite? && x >= 0
        end
        out.empty? ? nil : out
      end

      def props(p, config)
        return nil unless p.is_a?(Hash)
        out = {}
        p.each do |k, v|
          break if out.size >= MAX_PROPS
          key = str(k, 80) or next
          out[key] =
            if config.filtered_key?(key) then Config::FILTERED
            elsif v.is_a?(String) then v[0, MAX_PROP_VALUE]
            elsif v.is_a?(Integer) || v.is_a?(Float) || v == true || v == false then v
            else next
            end
        end
        out.empty? ? nil : out
      end

      # Plausible's scheme: a keyed hash of address, user agent and the UTC
      # day, so a visitor is countable across visits today and unlinkable
      # tomorrow. The address is hashed, never stored.
      def anonymous_visitor(config, address, user_agent)
        day = Time.now.utc.strftime("%Y-%m-%d")
        "a_" + Tracer.hmac_sha256_hex(config.api_key.to_s, "#{address}|#{user_agent}|#{day}")[0, 16]
      end

      # --- HTML injection -----------------------------------------------------------

      # Adds the script tag to a complete HTML response. Streamed (chunked)
      # bodies and anything that is not a 200 HTML page pass untouched.
      def inject(env, response)
        status, headers, body = response
        return response unless status.to_i == 200 && body
        type = header(headers, "content-type").to_s
        return response unless type.start_with?("text/html")
        return response if header(headers, "transfer-encoding").to_s.downcase.include?("chunked")
        html = buffer(body)
        return response if html.nil? || html.include?(SCRIPT_ROUTE)
        html = insert(html)
        set_header(headers, "content-length", html.bytesize.to_s)
        body.close if body.respond_to?(:close)
        [status, headers, [html]]
      rescue StandardError => e
        Glass.error("inject", e)
        response
      end

      def buffer(body)
        case body
        when String then body
        when Array then body.join
        else
          return nil unless body.respond_to?(:each)
          out = +""
          body.each { |chunk| out << chunk.to_s }
          out
        end
      end

      def insert(html)
        if (i = html.rindex(%r{</head>}i))
          html[0, i] + TAG + html[i..]
        elsif (i = html.rindex(%r{</body>}i))
          html[0, i] + TAG + html[i..]
        else
          html + TAG
        end
      end

      def header(headers, name)
        return nil unless headers
        headers.each { |k, v| return v if k.to_s.casecmp?(name) }
        nil
      end

      def set_header(headers, name, value)
        return unless headers
        headers.each_key { |k| return headers[k] = value if k.to_s.casecmp?(name) }
        headers[name] = value
      end
    end

    # visit id → who it belongs to, and whether a real request has vouched
    # for it. Bounded LRU: a beacon for a visit no request has ever carried
    # is allowed a small quota, so a page cannot flood the app's telemetry.
    module Visits
      MAX = 5_000
      @map = {}
      @mutex = Mutex.new

      class << self
        # A request carried X-Glass-Visit: the visit is real. With an
        # identified user, the join browser → server is remembered.
        def seen(visit, user = nil, keyed = nil)
          return unless visit
          @mutex.synchronize do
            e = take(visit) || { seen: false, events: 0, user: nil, keyed: nil }
            e[:seen] = true
            if keyed
              e[:user] = user
              e[:keyed] = keyed
            end
            put(visit, e)
          end
        end

        # The entry for a beacon, charging `count` events against the unseen
        # quota; nil once the quota is spent.
        def for_beacon(visit, count)
          @mutex.synchronize do
            e = take(visit) || { seen: false, events: 0, user: nil, keyed: nil }
            e[:events] += count
            put(visit, e)
            return nil if !e[:seen] && e[:events] > UNSEEN_QUOTA
            e.dup
          end
        end

        # Test seam: what the relay remembers of a visit.
        def lookup(visit)
          @mutex.synchronize { @map[visit]&.dup }
        end

        def reset!
          @mutex.synchronize { @map.clear }
        end

        private

        def take(visit)
          @map.delete(visit)
        end

        def put(visit, entry)
          @map[visit] = entry
          @map.shift while @map.size > MAX
        end
      end
    end

    # A small, honest user-agent parser: browser, OS and device class, and
    # nothing finer. The string itself never leaves the process.
    module UserAgent
      CACHE_MAX = 256
      @cache = BoundedCache.new(CACHE_MAX)

      class << self
        def parse(ua)
          @cache.fetch(ua.to_s) { |key| compute(key).freeze }
        end

        private

        def compute(ua)
          os =
            if ua.match?(/iPhone|iPad|iPod/) then "iOS"
            elsif ua.include?("Android") then "Android"
            elsif ua.match?(/Mac OS X|Macintosh/) then "macOS"
            elsif ua.include?("Windows") then "Windows"
            elsif ua.match?(/Linux|CrOS/) then "Linux"
            else "other"
            end
          browser =
            if ua.match?(/Edg(e|A|iOS)?\//) then "Edge"
            elsif ua.match?(/Firefox|FxiOS/) then "Firefox"
            elsif ua.match?(/Chrome|CriOS|Chromium/) then "Chrome"
            elsif ua.include?("Safari") then "Safari"
            else "other"
            end
          device =
            if ua.match?(/iPad|Tablet/) || (ua.include?("Android") && !ua.include?("Mobile")) then "tablet"
            elsif ua.match?(/Mobi|iPhone|iPod/) then "phone"
            else "desktop"
            end
          { "browser" => browser, "os" => os, "device" => device }
        end
      end
    end
  end
end
