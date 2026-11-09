# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class Triage < Base
      tool_name "triage"
      title "What needs fixing"
      description "What deserves attention across the fleet, worst first: jobs stuck running far past their habit, " \
        "endpoints and jobs that fail or got slower than their habit, an app's endpoints slowing together on new " \
        "database connections, where an app's time goes, N+1 queries, jobs waiting in their queue, error logs that " \
        "repeat, monitors alerting, pages with poor web vitals, failing model calls, agents that stopped reporting. " \
        "Each finding is compared with the window before the range. Findings a person dismissed in the console are " \
        "left out until they get worse, and ones they ignored are left out for good. Without `id` it lists findings — each with an " \
        "`id`, a severity, a title and a one-line summary. With `id` it answers that finding as a Markdown brief: " \
        "what is wrong, the facts, the evidence (traces, logs, profile functions, deploys), the filter for its rows " \
        "and the steps to fix it. Ask for the brief with the same range you listed with."
      input_schema(
        properties: {
          id: { type: "string", description: "A finding's id from the list. Omit to list findings." },
          app: { type: "string", description: "An app's slug. Omit for the whole fleet." },
          from: time_property("Start of the range. Default one day before `to`."),
          to: time_property("End of the range. Default now."),
          limit: { type: "integer", description: "1–40, default 20. Ignored with `id`." }
        },
        required: []
      )
      annotations(title: "What needs fixing", **READ_ONLY)

      DEFAULT_SPAN = T.let(1.day, ActiveSupport::Duration)

      sig { params(server_context: T.untyped, arguments: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **arguments)
        household = context_household(server_context)
        from, to = TimeRange.resolve(from: arguments[:from], to: arguments[:to], default: DEFAULT_SPAN)
        window = ::Triage::Window.around(from: from, to: to)
        id = arguments[:id].to_s.strip
        return brief(household, window, id) unless id.empty?

        answer do
          context = Query::Context.new(household)
          app = app_slug(context, arguments[:app])
          report = ::Triage.report(household, window: window, app: app, context: context)
          findings = report.findings.first(limit_of(arguments[:limit], default: 20, max: 40))
          { from: McpSerializer.time(window.from), to: McpSerializer.time(window.to),
            compared_with: { from: McpSerializer.time(window.baseline_from), to: McpSerializer.time(window.baseline_to) },
            findings: findings.map { |finding| finding_json(finding) },
            dismissed_or_ignored: report.hidden.size.positive? ? report.hidden.size : nil }.compact
        end
      rescue Query::Invalid => e
        failure(e.message)
      end

      sig { params(household: Household, window: ::Triage::Window, id: String).returns(MCP::Tool::Response) }
      def self.brief(household, window, id)
        subject = ::Triage::Subject.parse(id)
        return failure("No finding has the id “#{id}” — list findings without `id` and use one of theirs") if subject.nil?

        detail = ::Triage.detail(household, window: window, subject: subject)
        if detail.nil?
          return failure("That finding no longer stands out between #{McpSerializer.time(window.from)} and " \
            "#{McpSerializer.time(window.to)} — ask with the range you listed it with, or list again")
        end

        MCP::Tool::Response.new([ { type: "text", text: ::Triage::Brief.render(detail, window: window) } ])
      end
      private_class_method :brief

      sig { params(finding: ::Triage::Finding).returns(T::Hash[Symbol, T.untyped]) }
      def self.finding_json(finding)
        McpSerializer.compact(
          id: finding.subject.id, severity: finding.severity.serialize, kind: finding.subject.kind.serialize,
          app: finding.subject.app, title: finding.title, summary: finding.summary
        )
      end
      private_class_method :finding_json
    end
  end
end
