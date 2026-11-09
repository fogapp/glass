# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # The same error-level log line, again and again: something the app
    # knows is wrong and says so, whether or not the request failed.
    class LogErrors < Detector
      MIN_COUNT = 5
      LEVELS = "level:error,fatal"

      sig { override.returns(Kind) }
      def self.kind = Kind::LogErrors

      sig { override.returns(T::Array[Finding]) }
      def findings
        prior = counts(baseline: true)
        logged_before = apps_that_logged_before
        counts.filter_map do |key, count|
          next if count < MIN_COUNT

          app, message = key
          was = prior[key]
          # New only if the app was logging before and never said this.
          fresh = was.nil? && logged_before.include?(app)
          subject = Subject.new(kind: self.class.kind, app: app, work: nil, name: message.to_s)
          score = 10 + 30 * scale(Math.log10(count), 3.0) + (fresh ? 15 : 0)
          finding(subject, score: score,
            title: "#{app} logs “#{Words.clip(message, 80)}”",
            summary: "Logged at error level #{Words.count(count)} times in range#{before_text(was, fresh)}.",
            figures: { "count" => count, "count_before" => was, "new" => fresh })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        lines = scan.list(source: "logs", filter: filter, limit: 12)
        traced = lines.filter_map { |line| line["trace"] }.uniq.first(8)
        by = ->(field, title) { table(title, [ column(field, title.delete_prefix("By ").capitalize), column("count", "Lines") ],
          scan.table(source: "logs", group_by: [ field ], compute: %w[count], filter: filter, limit: 8)) }
        evidence = [
          chart("How often", scan.chart(source: "logs", filter: filter, compute: %w[count])),
          logs("Latest lines", filter),
          (traced.any? ? traces("The requests and jobs that logged it", "trace:#{traced.join(',')}") : nil),
          by.call("release", "By release"),
          by.call("source", "By source"),
          markers(subject.app)
        ]
        Detail.build(finding: finding,
          description: "An error-level line is the app saying something went wrong — a rescued " \
                       "exception, a failed call it retried, a value it could not handle. Repeating lines are worth " \
                       "reading even when no request failed: they are often the early sign of one that will. The lines and " \
                       "the requests that wrote them are below; the source names the logger.",
          facts: [ fact("App", subject.app), fact("Message", subject.name), fact("Lines in range", Words.count(finding.figures["count"])) ].compact,
          evidence: evidence,
          steps: [
            "Search the code for where this message is logged, and read the condition that leads there.",
            "Open the requests or jobs that logged it (get_trace) to see the inputs and what happened around it.",
            "Fix the condition — or, if it is expected, log it at a lower level so it stops reading as an error.",
            "Done when the line stops appearing at error level."
          ],
          source: "logs", filter: filter)
      end

      private

      sig { params(was: T.nilable(Float), fresh: T::Boolean).returns(String) }
      def before_text(was, fresh)
        return " (#{Words.count(was)} in the longer window before)" if was
        return ", and never in the window before" if fresh

        ""
      end

      # The apps with any log lines in the baseline: without them, "never
      # said before" only means "was not reporting before".
      sig { returns(T::Set[T.untyped]) }
      def apps_that_logged_before
        rows = scan.table(source: "logs", group_by: %w[app], compute: %w[count], filter: scan.filter, baseline: true)
        rows.filter_map { |row| row["app"] if row["count"].to_f.positive? }.to_set
      end

      sig { override.params(subject: Subject).returns(String) }
      def subject_terms(subject) = [ LEVELS, Query::Filter.quote("message", subject.name) ].join(" ")

      # The commonest messages in range by app; with `baseline`, the same
      # messages' counts in the window before — read for them, not ranked
      # against everything else said then.
      sig { params(baseline: T::Boolean).returns(T::Hash[T::Array[T.untyped], Float]) }
      def counts(baseline: false)
        reading = { source: "logs", group_by: %w[app message], compute: %w[count], filter: scan.filter(narrow || LEVELS) }
        rows = scan.table(**reading, limit: 100)
        rows = scan.baseline(**reading, found: rows) if baseline
        scan.keyed(rows, reading[:group_by]).transform_values { |row| row["count"].to_f }
      end
    end
  end
end
