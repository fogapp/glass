# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    # Shared spine for Glass's MCP tools:
    # expected failures return `failure(...)` as a sentence the agent can act
    # on, never a raised exception; results are JSON in a text block.
    #
    # A tool is the console's read path with an agent's manners: it asks
    # through Query::Context (so it can only ever see the token's household),
    # takes times the way a person says them (Mcp::TimeRange) and answers
    # through McpSerializer.
    class Base < MCP::Tool
      extend T::Sig

      READ_ONLY = T.let({ read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }.freeze,
        T::Hash[Symbol, T::Boolean])

      # The schema of a time bound, shared by every tool that takes a range.
      TIME = T.let({ type: %w[string number] }.freeze, T::Hash[Symbol, T.untyped])

      # Whether the tool only looks. All a read-scoped token or a guest may
      # use (Mcp::Toolbox); a tool that changes anything overrides this.
      sig { returns(T::Boolean) }
      def self.read_only? = true

      sig { params(description: String).returns(T::Hash[Symbol, T.untyped]) }
      def self.time_property(description) = TIME.merge(description: description)

      # Compact, not pretty: a timeseries is hundreds of numbers, and one per
      # line is three tokens of whitespace for each.
      sig { params(payload: T.untyped).returns(MCP::Tool::Response) }
      def self.json_response(payload)
        MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload.as_json) } ])
      end

      sig { params(message: String).returns(MCP::Tool::Response) }
      def self.failure(message)
        MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
      end

      # Runs the tool's body. A question the engine cannot answer — an
      # unknown field, a range that makes no sense, a statement that timed
      # out — comes back as the compiler's own sentence, which says what to
      # change; the agent reads it and asks again.
      sig { params(blk: T.proc.returns(T.untyped)).returns(MCP::Tool::Response) }
      def self.answer(&blk)
        json_response(yield)
      rescue Query::Invalid => e
        failure(e.message)
      end

      # A question for the query engine (Query::Request, Query::Runner) over
      # [from, to): the rest of `params` are the request's own (`filter`,
      # `compute`, `group_by`, `limit`, …), as the console would post them.
      sig do
        params(context: Query::Context, source: String, shape: String, from: Time, to: Time, params: T.untyped)
          .returns(T::Hash[Symbol, T.untyped])
      end
      def self.ask(context, source:, shape:, from:, to:, **params)
        Query::Runner.run(request_of(source, shape, from, to, params), context)
      end

      # …and the rows of its answer.
      sig do
        params(context: Query::Context, source: String, shape: String, from: Time, to: Time, params: T.untyped)
          .returns(T::Array[T::Hash[String, T.untyped]])
      end
      def self.rows(context, source:, shape:, from:, to:, **params)
        Query::Runner.run(request_of(source, shape, from, to, params), context).fetch(:rows)
      end

      sig do
        params(source: String, shape: String, from: Time, to: Time, params: T::Hash[Symbol, T.untyped]).returns(Query::Request)
      end
      def self.request_of(source, shape, from, to, params)
        Query::Request.from_params(
          { "source" => source, "shape" => shape, "from" => from.to_f, "to" => to.to_f }.merge(params.transform_keys(&:to_s))
        )
      end
      private_class_method :request_of

      sig { params(server_context: T.untyped).returns(User) }
      def self.context_user(server_context) = T.cast(server_context[:user], User)

      sig { params(server_context: T.untyped).returns(Household) }
      def self.context_household(server_context) = T.cast(server_context[:household], Household)

      sig { params(server_context: T.untyped).returns(Query::Context) }
      def self.query_context(server_context) = Query::Context.new(context_household(server_context))

      # An `app` argument as a slug the household has; nil when none was
      # given. An app it does not have is said so, with the ones it does —
      # unlike a typed filter, where an unknown app quietly matches nothing.
      sig { params(context: Query::Context, app: T.untyped).returns(T.nilable(String)) }
      def self.app_slug(context, app)
        slug = app.to_s.strip.downcase
        return nil if slug.empty?
        return slug if context.app_id(slug)

        known = context.slugs
        raise Query::Invalid, "No app “#{slug}” — #{known.empty? ? 'no apps report yet' : "apps are #{known.join(', ')}"}"
      end

      # …and as a filter term.
      sig { params(context: Query::Context, app: T.untyped).returns(T.nilable(String)) }
      def self.app_term(context, app)
        slug = app_slug(context, app)
        slug && "app:#{slug}"
      end

      # `key:"value"` for a value that may hold spaces or quotes — an
      # endpoint's name, a job class. nil for a blank value.
      sig { params(key: String, value: T.untyped).returns(T.nilable(String)) }
      def self.quoted_term(key, value)
        text = value.to_s.strip
        text.empty? ? nil : Query::Filter.quote(key, text)
      end

      # The entry of `map` an argument names, or the default's when it names
      # none; a name it does not hold is said so, with the ones it does.
      sig do
        type_parameters(:V).params(map: T::Hash[String, T.type_parameter(:V)], value: T.untyped, default: String, name: String)
          .returns(T.type_parameter(:V))
      end
      def self.choice(map, value, default:, name:)
        map.fetch(value.to_s.presence || default) do
          raise Query::Invalid, "Cannot #{name} “#{value}” — one of #{map.keys.join(', ')}"
        end
      end

      # A row's figures under the keys a tool answers them with: `computes`
      # maps each compute to its key.
      sig { params(computes: T::Hash[String, Symbol], row: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def self.figures(computes, row) = computes.to_h { |compute, key| [ key, McpSerializer.number(row[compute]) ] }

      sig { params(value: T.untyped, default: Integer, max: Integer).returns(Integer) }
      def self.limit_of(value, default:, max:) = (value.nil? ? default : value.to_i).clamp(1, max)

      # The terms of a filter, joined; blanks dropped.
      sig { params(terms: T.untyped).returns(String) }
      def self.filter_of(*terms) = terms.filter_map { |term| term.to_s.strip.presence }.join(" ")
    end
  end
end
