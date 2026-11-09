# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class TailLogs < Base
      LEVELS = Telemetry::LogLine::LEVELS

      tool_name "tail_logs"
      title "Tail logs"
      description "The newest log lines, newest first: time, app, level, message, the trace that wrote each one, " \
        "and its structured attributes. Narrow by app, by a minimum level (`min_level: \"warn\"` is warn, error and " \
        "fatal), and by `filter` — free text searches the message (`\"connection refused\"`), terms match fields " \
        "(`source:`, `process:`, `release:`, `trace:`, `@attribute:`). To read further back, pass the answer's " \
        "`next_before` as `before`."
      input_schema(
        properties: {
          app: { type: "string", description: "An app's slug. Omit for the whole fleet." },
          min_level: { type: "string", enum: LEVELS, description: "The lowest level to show. Default all levels." },
          filter: { type: "string", description: "Free text and filter terms over logs." },
          from: time_property("Start of the range. Default 15 minutes before `to`."),
          to: time_property("End of the range. Default now."),
          before: time_property("Only lines older than this: the previous answer's next_before."),
          limit: { type: "integer", description: "1–200, default 50." }
        },
        required: []
      )
      annotations(title: "Tail logs", **READ_ONLY)

      sig { params(server_context: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **arguments)
        answer do
          context = query_context(server_context)
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to], default: 15.minutes)
          result = ask(context, source: "logs", shape: "list", from: from, to: to,
            filter: filter_of(app_term(context, arguments[:app]), level_term(arguments[:min_level]), arguments[:filter]),
            limit: limit_of(arguments[:limit], default: 50, max: 200), before: TimeRange.optional(arguments[:before], "before")&.to_f)
          McpSerializer.query_json(result).except(:shape)
        end
      end

      sig { params(level: T.untyped).returns(T.nilable(String)) }
      def self.level_term(level)
        name = level.to_s.strip.downcase
        return nil if name.empty?

        index = LEVELS.index(name) || raise(Query::Invalid, "Unknown level “#{name}” — one of #{LEVELS.join(', ')}")
        "level:#{LEVELS.drop(index).join(',')}"
      end
      private_class_method :level_term
    end
  end
end
