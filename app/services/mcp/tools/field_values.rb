# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class FieldValues < Base
      tool_name "field_values"
      title "The values a field takes"
      description "The most common values of one field in a range, with how many rows carry each (top 50) — what " \
        "the query bar offers after `name:`. Use it to find the exact spelling of an endpoint, a job, an error " \
        "class, a release or a route before filtering on it. For a metric's tag, pass source “metrics” and `metric`."
      input_schema(
        properties: {
          source: { type: "string", enum: RunQuery::SOURCES, description: "The source the field belongs to." },
          field: { type: "string", description: "A field name (see describe_data), an @attribute, or a metric's tag." },
          from: time_property("Start of the range. Default one day before `to`."),
          to: time_property("End of the range. Default now."),
          filter: { type: "string", description: "Only count rows matching this filter." },
          prefix: { type: "string", description: "Only values starting with this (case-insensitive)." },
          metric: { type: "string", description: "The metric name, for source “metrics”." }
        },
        required: %w[source field]
      )
      annotations(title: "The values a field takes", **READ_ONLY)

      sig { params(server_context: T.untyped, source: T.untyped, field: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, source:, field:, **arguments)
        answer do
          from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to], default: 1.day)
          values = Query::Catalog.values(
            context: query_context(server_context), source: source.to_s, key: field.to_s, from: from, to: to,
            filter: arguments[:filter].to_s, prefix: arguments[:prefix].to_s.presence, metric: arguments[:metric].to_s.presence
          )
          { source: source.to_s, field: field.to_s, from: McpSerializer.time(from), to: McpSerializer.time(to),
            values: values.map { |row| McpSerializer.compact(McpSerializer.numbers(row)) } }
        end
      end
    end
  end
end
