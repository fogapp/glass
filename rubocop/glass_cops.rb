# typed: false
# frozen_string_literal: true

# House cops. Each encodes a bug class that shipped once.
module RuboCop
  module Cop
    module Glass
      # T.cast(params[:x], String) turns bad input into a 500. Narrow with
      # .to_s / params.require so it 400s instead.
      class NoParamsCast < Base
        MSG = "Never T.cast params values — narrow with .to_s / params.require so bad input 400s instead of 500ing."

        def_node_matcher :params_cast?, <<~PATTERN
          (send (const nil? :T) :cast (send (send nil? :params) :[] ...) ...)
        PATTERN

        def on_send(node)
          add_offense(node) if params_cast?(node)
        end
      end

      # The only error envelope is { errors: [...] } via render_errors.
      # { ok: false, error: } is allowed — it's the test_connection contract.
      class NoSingularErrorRender < Base
        MSG = "Use render_errors ({ errors: [...] }) — a bare { error: ... } render fragments the client's error handling."

        def on_send(node)
          return unless node.method?(:render)

          hash = node.first_argument
          return unless hash&.hash_type?

          json_pair = hash.pairs.find { |p| p.key.sym_type? && p.key.value == :json }
          payload = json_pair&.value
          return unless payload&.hash_type?

          keys = payload.pairs.filter_map { |p| p.key.sym_type? ? p.key.value : nil }
          add_offense(node) if keys.include?(:error) && !keys.include?(:ok)
        end
      end

      # SomeEnum.deserialize(other.serialize) bridges two enums positionally —
      # write an explicit exhaustive mapping method with T.absurd instead.
      class NoCrossEnumDeserialize < Base
        MSG = "Never bridge enums with X.deserialize(y.serialize) — write an explicit exhaustive mapping (T.absurd)."

        def_node_matcher :cross_deserialize?, <<~PATTERN
          (send _ {:deserialize :try_deserialize} (send _ :serialize))
        PATTERN

        def on_send(node)
          add_offense(node) if cross_deserialize?(node)
        end
      end

      # Upstream HTTP goes through UpstreamHttpClient (timeouts, breaker,
      # typed errors) — raw Net::HTTP in app code bypasses all three. The
      # n8n-style connector threat model makes disciplined egress a security
      # property here, not a style one.
      class NoRawNetHttp < Base
        MSG = "No raw HTTP egress outside UpstreamHttpClient — connectors get timeouts, circuit breaking, and typed errors from the shared client."

        def_node_matcher :net_http?, <<~PATTERN
          (send (const (const {nil? cbase} :Net) :HTTP) {:start :get :post :get_response :new} ...)
        PATTERN

        # OpenURI is Net::HTTP wearing a trench coat: `URI.open` and bare
        # `open("http://…")` fetch URLs with none of the shared client's
        # discipline, and would have slipped this fence entirely.
        def_node_matcher :uri_open?, <<~PATTERN
          (send (const {nil? cbase} :URI) :open ...)
        PATTERN

        def on_send(node)
          add_offense(node) if net_http?(node) || uri_open?(node)
        end
      end

      # The companion to NoRawNetHttp. Routing through the shared client is
      # only a security property while the client refuses to fetch the
      # machine's own network — a URL someone else chose, or a redirect they
      # control, is the whole attack. Opting out is legitimate only for
      # infrastructure the household configured (fog itself, ntfy, sibling
      # apps on the fog network), so it must be a decision someone made
      # on purpose rather than one that spread by copy-paste.
      class NoUnreviewedPrivateEgress < Base
        MSG = "allow_private_addresses? lets this client reach the machine's own network. That is only right for endpoints the household configured and expects to be private (fog, ntfy, sibling apps on the fog network). If this is one of those, add `# rubocop:disable Glass/NoUnreviewedPrivateEgress` with a note saying why."

        def_node_matcher :allows_private?, <<~PATTERN
          (def :allow_private_addresses? (args) (true))
        PATTERN

        def on_def(node)
          add_offense(node) if allows_private?(node)
        end
      end
    end
  end
end
