# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # A monitor alerting right now: the condition someone already decided
    # was worth being woken for.
    class Incidents < Detector
      sig { override.returns(Kind) }
      def self.kind = Kind::Incident

      sig { override.returns(T::Array[Finding]) }
      def findings
        return [] unless window.current?

        scope = scan.household.incidents.open.includes(:monitor)
        scope = scope.where(app_slug: scan.app) if scan.app
        if (subject = scan.subject)
          scope = scope.where(monitor_id: subject.name)
        end
        scope.order(opened_at: :desc).limit(20).map do |incident|
          rule = T.must(incident.monitor)
          peak = incident.peak_value
          last = rule.last_value
          subject = Subject.new(kind: self.class.kind, app: incident.app_slug, work: nil, name: rule.id.to_s)
          finding(subject, score: rule.notify ? 88 : 75,
            title: "#{rule.name} is alerting",
            summary: "#{rule.condition_text} — open since #{incident.opened_at.utc.iso8601}" \
                     "#{peak ? ", worst value #{peak.round(3)}" : ''}#{last ? ", now #{last.round(3)}" : ''}.",
            figures: { "opened_at" => incident.opened_at.to_f, "peak" => incident.peak_value, "last_value" => rule.last_value,
                       "monitor_id" => rule.id })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        rule = scan.household.monitors.find(finding.subject.name)
        query = rule.query
        opened = Time.at(finding.figures["opened_at"].to_f).utc
        spec = {
          "source" => query["source"], "shape" => "timeseries", "from" => [ opened - 1.hour, window.baseline_from ].max.to_f,
          "to" => window.to.to_f, "filter" => query["filter"].to_s, "compute" => [ query["compute"].presence || "count" ],
          "metric" => query["metric"].presence
        }.compact
        Detail.build(finding: finding,
          description: "A monitor is a saved question with a condition; this one's condition has held " \
                       "long enough to open an incident#{rule.notify ? ' and push a notification' : ''}. " \
                       "#{rule.description.presence || 'The monitor has no notes on what to do when it fires.'} The chart is " \
                       "the monitor's own query since shortly before it opened. Other findings for the same app are likely " \
                       "the cause — start there.",
          facts: [ fact("Monitor", rule.name), fact("Condition", rule.condition_text), fact("App", finding.subject.app),
                   fact("Opened", opened.iso8601), fact("Query", [ query["source"], query["metric"], query["filter"] ].compact_blank.join(" · ")) ].compact,
          evidence: [ chart(rule.condition_text, spec), markers(finding.subject.app) ],
          steps: [
            "Run the monitor's query (query) over the incident's window to see when and how sharply it changed.",
            "Look at the other Triage findings and the deploys for #{finding.subject.app || 'the app'} around the time it opened.",
            "Fix the cause; the incident closes itself once the condition stops holding."
          ],
          source: query["source"].to_s, filter: query["filter"].to_s)
      end
    end
  end
end
