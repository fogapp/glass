# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # Calls to a model that fail: a provider erroring, a rate limit, a
    # request the model refused, a timeout.
    class ModelErrors < Detector
      MIN_ERRORS = 3
      MIN_RATE = 0.05

      sig { override.returns(Kind) }
      def self.kind = Kind::ModelErrors

      sig { override.returns(T::Array[Finding]) }
      def findings
        prior = rows(baseline: true)
        rows.filter_map do |key, row|
          errors = row["errors"].to_f
          rate = row["error_rate"].to_f
          next if errors < MIN_ERRORS || rate < MIN_RATE

          app, provider, model = key
          was = prior[key]&.dig("error_rate")
          subject = Subject.new(kind: self.class.kind, app: app, work: provider, name: model.to_s)
          score = 30 + 40 * scale(rate, 0.3) + 15 * scale(Math.log10(errors), 2.0)
          finding(subject, score: score,
            title: "#{app} · #{model} calls are failing",
            summary: "#{Words.percent(rate)} of #{Words.count(row['count'])} calls to #{provider} #{model} failed " \
                     "(#{Words.count(errors)})#{was ? ", against #{Words.percent(was)} before" : ''}.",
            figures: { "count" => row["count"], "errors" => errors, "error_rate" => rate, "error_rate_before" => was, "cost" => row["sum(cost)"] })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        failed = scan.list(source: "model_calls", filter: "#{filter} status:error", limit: 10)
        evidence = [
          chart("Calls and errors", scan.chart(source: "model_calls", filter: filter, compute: %w[count errors])),
          table("Error classes", [ column("error", "Error"), column("count", "Calls") ],
            scan.table(source: "model_calls", group_by: %w[error], compute: %w[count], filter: "#{filter} status:error", limit: 8)),
          table("By purpose", [ column("purpose", "Purpose"), column("count", "Calls"), column("error_rate", "Error rate", "ratio") ],
            scan.table(source: "model_calls", group_by: %w[purpose], compute: %w[count error_rate], filter: filter, limit: 8)),
          table("Latest failures", [ column("ts", "When", "time"), column("error", "Error"), column("stop", "Stop"),
            column("duration", "Duration", "ms"), column("trace", "Trace", "trace") ], failed)
        ]
        Detail.build(finding: finding,
          description: "Each row of model_calls is one call as the agent made it — never a prompt or a " \
                       "completion — so the evidence is the error class, the stop reason and the trace of the run around it. " \
                       "Rate limits and overloads want backoff and a fallback model; timeouts want a streaming call or a " \
                       "longer deadline; a 4xx usually means the request itself is wrong (a tool schema, a context too long).",
          facts: [ fact("App", subject.app), fact("Provider", subject.work), fact("Model", subject.name),
                   fact("Calls in range", Words.count(finding.figures["count"])) ].compact,
          evidence: evidence,
          steps: [
            "Read the error classes: rate limiting, overload, timeout and invalid request each have a different fix.",
            "Open a failed call's trace (get_trace) to see the run it broke and whether the harness retried or fell back.",
            "Fix the call site — backoff and retry, a fallback model, a smaller context, a corrected tool schema.",
            "Done when the error rate is back under #{Words.percent(MIN_RATE)}."
          ],
          source: "model_calls", filter: filter)
      end

      private

      sig { override.params(subject: Subject).returns(String) }
      def subject_terms(subject)
        [ subject.work && Query::Filter.quote("provider", subject.work), Query::Filter.quote("model", subject.name) ].compact.join(" ")
      end

      sig { params(baseline: T::Boolean).returns(T::Hash[T::Array[T.untyped], Row]) }
      def rows(baseline: false)
        group_by = %w[app provider model]
        found = scan.table(source: "model_calls", group_by: group_by, compute: [ "count", "errors", "error_rate", "sum(cost)" ],
          filter: scan.filter(narrow), baseline: baseline)
        scan.keyed(found, group_by)
      end
    end
  end
end
