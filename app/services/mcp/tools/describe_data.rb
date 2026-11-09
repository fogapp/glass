# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class DescribeData < Base
      MAX_METRICS = 200

      tool_name "describe_data"
      title "What there is to ask about"
      description "The catalog `query` reads from: each source (transactions, spans, logs, profiles, page_events, " \
        "visits, model_calls) with the fields a filter, a group_by and a compute may name; the kinds of transaction " \
        "(request, job, run) and the facets — groups of fields — each carries; the functions; and the metrics that " \
        "have been reported, with their kind, unit and tags. Pass `source` for one source's fields only, or " \
        "`source: \"metrics\"` with `metric_prefix` to find a metric. Call this before writing a query against a " \
        "source you have not used yet."
      input_schema(
        properties: {
          source: { type: "string", description: "One source's name, or “metrics”. Omit for every source (without the metric list)." },
          metric_prefix: { type: "string", description: "Only metrics whose name starts with this, e.g. “rails.” or “fog.container”." }
        },
        required: []
      )
      annotations(title: "What there is to ask about", **READ_ONLY)

      sig { params(server_context: T.untyped, source: T.untyped, metric_prefix: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, source: nil, metric_prefix: nil, **_extra)
        answer do
          name = source.to_s.strip.downcase
          prefix = metric_prefix.to_s.strip
          catalog = Query::Catalog.describe(query_context(server_context), metrics: name.empty? || name == "metrics")
          if name == "metrics" || (name.empty? && prefix.present?)
            metrics(catalog, prefix)
          elsif name.empty?
            { sources: catalog[:sources].map { |entry| source_json(entry) }, kinds: catalog[:kinds],
              functions: catalog[:functions], apps: catalog[:apps],
              metrics: "#{catalog[:metrics].size} reported — list them with source: \"metrics\"" }
          else
            Query::Sources.fetch(name)
            source_json(catalog[:sources].find { |entry| entry[:name] == name })
              .merge(functions: catalog[:functions][:events], kinds: name == "transactions" ? catalog[:kinds] : nil).compact
          end
        end
      end

      sig { params(catalog: T::Hash[Symbol, T.untyped], prefix: String).returns(T::Hash[Symbol, T.untyped]) }
      def self.metrics(catalog, prefix)
        matching = catalog[:metrics].select { |metric| metric[:name].to_s.start_with?(prefix) }
        { functions: catalog[:functions][:metrics], total: matching.size,
          truncated: matching.size > MAX_METRICS ? "showing #{MAX_METRICS} — narrow with metric_prefix" : nil,
          metrics: matching.first(MAX_METRICS).map { |metric| McpSerializer.compact(metric) } }.compact
      end
      private_class_method :metrics

      sig { params(entry: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def self.source_json(entry)
        { name: entry[:name], label: entry[:label], fields: entry[:fields].map { |field| McpSerializer.compact(field) } }
      end
      private_class_method :source_json
    end
  end
end
