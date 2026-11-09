# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    # One conversation with an agent harness, as the interactions it was
    # made of, in order.
    class GetSession < Base
      FIELDS = T.let(%w[ts name trigger channel status stop error model duration active queue_ms prep model_ms tool_ms wait deliver
                        lag ttft stall rounds calls tools tool_errors tokens_in tokens_out cache_read cost trace].freeze,
        T::Array[String])
      LOOKBACK = T.let(30.days, ActiveSupport::Duration)

      tool_name "get_session"
      title "One conversation, in order"
      description "A session of an agent harness — one conversation — as the runs it was made of, oldest first: for " \
        "each, when it began, the agent, why it ran (trigger) and where the person was (channel), how it ended " \
        "(status, stop), how long it took and where the time went (queue, prep, model, tool, waiting on a person, " \
        "deliver — all ms; `active` is the duration less the waiting on a person), how long until the first visible " \
        "text (ttft) and the longest silence (stall), and what it spent (tokens, cost in USD). Background work the " \
        "conversation caused (compaction, reflection) is included. Session ids come from `query` on transactions " \
        "(filter kind:run — every run row carries `session`) or from `model_usage` grouped by session. Follow up " \
        "with `get_trace` on a run's `trace` for its steps and model calls. Glass never holds what was said."
      input_schema(
        properties: {
          session: { type: "string", description: "The session id, as a run row carries it." },
          app: { type: "string", description: "The app's slug, when two apps could share a session id." },
          from: time_property("Start of the range. Default thirty days before `to`."),
          to: time_property("End of the range. Default now."),
          limit: { type: "integer", description: "The most recent N runs, 1–200. Default 50." }
        },
        required: %w[session]
      )
      annotations(title: "One conversation, in order", **READ_ONLY)

      sig { params(server_context: T.untyped, session: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, session:, **arguments)
        answer do
          context = query_context(server_context)
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to], default: LOOKBACK)
          filter = filter_of(app_term(context, arguments[:app]), "kind:run", quoted_term("session", session))
          raise Query::Invalid, "`session` is required: a session id, as a run row carries it" if session.to_s.strip.empty?

          rows = rows(context, source: "transactions", shape: "list", from: from, to: to, filter: filter,
            limit: limit_of(arguments[:limit], default: 50, max: 200))
          raise Query::Invalid, missing(session.to_s, from) if rows.empty?

          totals = rows(context, source: "transactions", shape: "table", from: from, to: to, filter: filter,
            compute: [ "count", "sum(cost)", "sum(tokens_in)", "sum(tokens_out)", "sum(active)", "sum(wait)" ]).first.to_h
          { session: session.to_s, app: rows.first&.fetch("app", nil), first_at: McpSerializer.time(rows.last&.fetch("ts")),
            last_at: McpSerializer.time(rows.first&.fetch("ts")),
            totals: McpSerializer.numbers(runs: totals["count"], cost_usd: totals["sum(cost)"], input_tokens: totals["sum(tokens_in)"],
              output_tokens: totals["sum(tokens_out)"], active_ms: totals["sum(active)"], waiting_on_a_person_ms: totals["sum(wait)"]),
            runs: rows.reverse.map { |row| run_json(row) } }
        end
      end

      sig { params(session: String, from: Time).returns(String) }
      def self.missing(session, from)
        "No runs under session “#{session}” since #{McpSerializer.time(from)} — it never reported, or has aged out of retention."
      end
      private_class_method :missing

      sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def self.run_json(row)
        active = [ row["duration"].to_f - row["wait"].to_f, 0.0 ].max
        McpSerializer.numbers(McpSerializer.list_row(row.merge("active" => active).select { |key, _| FIELDS.include?(key) }))
      end
      private_class_method :run_json
    end
  end
end
