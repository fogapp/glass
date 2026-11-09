# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # An endpoint, job or agent run that ends in an error often enough to
    # matter — worse when it used to succeed.
    class Failing < WorkDetector
      MIN_ERRORS = 3
      MIN_RATE = 0.02
      # This many errors matter at any rate: a busy endpoint failing 1% of
      # the time is still a person seeing an error page every few minutes.
      ENOUGH_ERRORS = 25

      sig { override.returns(Kind) }
      def self.kind = Kind::Failing

      sig { override.returns(T::Array[Finding]) }
      def findings
        prior = before
        classes = error_classes
        now.filter_map do |key, row|
          errors = row["errors"].to_f
          rate = row["error_rate"].to_f
          next if errors < MIN_ERRORS || (rate < MIN_RATE && errors < ENOUGH_ERRORS)

          base = prior[key]
          was = base&.dig("error_rate")&.to_f
          rising = was.nil? || rate >= [ was * 2, was + 0.02 ].max
          subject = work_subject(key)
          top = classes[[ key[0], key[2] ]]
          score = 25 + 35 * scale(rate, 0.25) + 15 * scale(Math.log10(errors), 2.5) + (rising ? 20 : 0)
          finding(subject, score: score,
            title: "#{label(subject)} is failing",
            summary: "#{Words.percent(rate)} of #{Words.count(row['count'])} #{Words.noun(key[1], row['count'])} ended in an error " \
                     "(#{Words.count(errors)})#{was_text(was, base)}#{top ? " — mostly #{top}" : ''}.",
            figures: { "count" => row["count"], "errors" => errors, "error_rate" => rate, "error_rate_before" => was,
                       "count_before" => base&.dig("count"), "top_error" => top, "new" => base.nil? || base["errors"].to_f.zero? })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        classes = scan.table(source: "transactions", group_by: %w[error], compute: %w[count], filter: "#{filter} status:error", limit: 10)
        failing = scan.list(source: "transactions", filter: "#{filter} status:error", limit: 8)
        traces_with_logs = failing.filter_map { |sample| sample["trace"] }.uniq.first(8)
        evidence = [
          chart("Errors and error rate", scan.chart(source: "transactions", filter: filter, compute: %w[errors error_rate])),
          table("Error classes", [ column("error", "Error class"), column("count", "Count") ], classes),
          traces("Latest failures", "#{filter} status:error"),
          (subject.work == "request" ? by_status(filter) : nil),
          by_release(subject),
          (traces_with_logs.any? ? logs("What the failing requests logged", "trace:#{traces_with_logs.join(',')} level:warn,error,fatal") : nil),
          markers(subject.app)
        ]
        work_detail(finding,
          description: description(subject, finding),
          facts: work_facts(subject, subject_now) + [ fact("Top error", finding.figures["top_error"]) ].compact,
          evidence: evidence,
          steps: [
            "Open the latest failing traces (get_trace) and read the error, the span it happened in and the logs written before it.",
            "Find where the top error class is raised in #{subject.name} and the code it calls; reproduce it with the inputs the traces show.",
            "Check the release breakdown: if one release introduced it, read that release's diff first.",
            "Fix the cause rather than rescuing the error — and add a test that fails without the fix.",
            "Done when the error rate is back under #{Words.percent([ finding.figures['error_rate_before'].to_f, 0.005 ].max)} " \
            "with the same traffic."
          ])
      end

      private

      sig { params(was: T.nilable(Float), base: T.nilable(Row)).returns(String) }
      def was_text(was, base)
        return ", and nothing ran before" if base.nil?
        return ", where it never failed before" if was.to_f.zero?

        ", against #{Words.percent(was)} before"
      end

      # The commonest error class of each failing unit of work, by app and
      # name — a query groups by three fields at most, and a name is a
      # request's or a job's, rarely both.
      sig { returns(T::Hash[[ T.untyped, T.untyped ], String]) }
      def error_classes
        rows = scan.table(source: "transactions", group_by: %w[app name error], compute: %w[count],
          filter: scan.filter(narrow, "status:error"))
        rows.each_with_object({}) do |row, top|
          top[[ row["app"], row["name"] ]] ||= row["error"].to_s.presence
        end.compact
      end

      sig { params(filter: String).returns(Evidence) }
      def by_status(filter)
        rows = scan.table(source: "transactions", group_by: %w[http_status], compute: %w[count], filter: filter, limit: 10)
        table("By HTTP status", [ column("http_status", "Status"), column("count", "Count") ], rows)
      end

      sig { params(subject: Subject, finding: Finding).returns(String) }
      def description(subject, finding)
        what = Telemetry::Work.kind(subject.work.to_s).members
        "An error here means #{what} did not do what they were for: a person saw an error, or " \
          "work that was queued did not happen. The traces below are real failures from the range — each carries the " \
          "error class, its spans and the log lines written on the way. Start from the most common error class; when the " \
          "rate rose recently, compare the releases and the deploys listed below, since a change that lines up with the " \
          "rise is the likeliest cause. Error grouping and stack traces live in Flare; this is how often, since when, and " \
          "in which requests."
      end
    end
  end
end
