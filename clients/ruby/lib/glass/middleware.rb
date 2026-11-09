# frozen_string_literal: true

module Glass
  # The one Rack middleware, at the top of the stack: every request becomes
  # a transaction from the moment it enters Rack until the response is
  # returned (streaming bodies are not waited for). The controller
  # subscriber fills in the name, route and user; SQL, views and the rest
  # accumulate on the same fiber-local transaction.
  #
  # The browser relay rides on it: `relay` answers
  # `/_glass/*` itself — the script and the beacon endpoint — and `decorate`
  # injects the script tag into a complete HTML page while the `browser`
  # directive is on.
  class Middleware
    RELAY_PREFIX = "/_glass/"

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless Glass.enabled? && Glass.config.feature?(:requests)
      path = env["PATH_INFO"]
      if (reply = relay(env, path))
        return reply
      end
      return ignored(env) if Glass.config.ignore_path?(path)

      txn = begin
        Tracer.start_request(env)
      rescue StandardError => e
        Glass.error("request", e)
        nil
      end
      return @app.call(env) unless txn

      response = nil
      begin
        response = @app.call(env)
      rescue Exception => e
        finish(txn, 500, e)
        raise
      end
      finish(txn, response[0], nil)
      decorate(env, response)
    end

    private

    # An ignored request produces no transaction, no metrics and no logs:
    # Glass's own ingest endpoint must not report on itself,
    # and a health probe is not a finding.
    def ignored(env)
      Thread.current[:glass_muted] = true
      @app.call(env)
    ensure
      Thread.current[:glass_muted] = nil
    end

    def finish(txn, status, error)
      Tracer.finish_request(txn, status, error)
    rescue StandardError => e
      Thread.current[Tracer::KEY] = nil
      Glass.error("request", e)
    end

    # `/_glass/*` is answered here, never by the app: the script, the
    # beacon endpoint, and 404 for the rest. While the browser directive is
    # off the script is empty and a beacon is taken and dropped — not a 404:
    # a tag that sits in a page for good must not be an error in every
    # console. Nothing under it becomes a transaction or a log line. nil
    # means "not ours".
    def relay(env, path)
      return nil unless path&.start_with?(RELAY_PREFIX)
      Thread.current[:glass_muted] = true
      config = Glass.config
      active = config.browser_active?
      method = env["REQUEST_METHOD"]
      if path == Relay::SCRIPT_ROUTE && (method == "GET" || method == "HEAD")
        active ? Relay.serve_script(env) : Relay.idle_script
      elsif path == Relay::BEACON_ROUTE && method == "POST"
        active ? Relay.beacon(env, config) : [204, {}, Relay::NO_BODY]
      else
        [404, {}, Relay::NO_BODY]
      end
    rescue StandardError => e
      Glass.error("relay", e)
      [404, {}, Relay::NO_BODY]
    ensure
      Thread.current[:glass_muted] = nil
    end

    # With the `browser` directive on, a complete HTML page gets
    # `<script defer src="/_glass/glass.js">` before </head>.
    def decorate(env, response)
      return response unless Glass.config.browser_active?
      Relay.inject(env, response)
    end
  end
end
