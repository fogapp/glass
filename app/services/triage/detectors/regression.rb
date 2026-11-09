# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # An endpoint or job whose p95 is well above its own habit, and slow in
    # its own right: something changed — a deploy, a table that grew, a
    # dependency that slowed. A fast endpoint that got less fast is not a
    # finding however large the ratio, and one whose slow requests are the
    # moments its app stalled (Triage::Stalls) is that finding's, not its own.
    class Regression < WorkDetector
      MIN_COUNT = 20
      MIN_RATIO = 1.5
      # Below this a doubling is a rounding error nobody feels.
      MIN_DELTA_MS = 50.0
      # What a severity is sized by: the p95's growth, and the time every
      # call lost together (the average's growth times the calls) at a
      # day's rate, so a short range is not a small one — the sizes at
      # which each counts in full, for a page waited on and for a job.
      FULL_DELTA_MS = 1_000.0
      FULL_JOB_DELTA_MS = 60_000.0
      FULL_LOST_MS = 600_000.0
      FULL_JOB_LOST_MS = 7_200_000.0

      sig { override.returns(Kind) }
      def self.kind = Kind::Regression

      sig { override.returns(T::Array[Finding]) }
      def findings
        prior = before
        stalls = scan.stalls
        now.filter_map do |key, row|
          next unless Telemetry::Work::TIMED.include?(key[1])

          base = prior[key]
          next if base.nil? || row["count"].to_f < MIN_COUNT || base["count"].to_f < MIN_COUNT

          p95 = row["p95(duration)"].to_f
          was = base["p95(duration)"].to_f
          next unless was.positive?

          ratio = p95 / was
          next if ratio < MIN_RATIO || p95 - was < MIN_DELTA_MS || !slow?(key[1], p95)
          next if key[1] == "request" && stalls.explains?(key[0], key[2].to_s)

          subject = work_subject(key)
          moved = biggest_move(row, base)
          lost = row["count"].to_f * [ row["avg(duration)"].to_f - base["avg(duration)"].to_f, 0.0 ].max
          job = key[1] == "job"
          daily = lost * 1.day.to_f / (window.to - window.from)
          score = 25 + 30 * scale(p95 - was, job ? FULL_JOB_DELTA_MS : FULL_DELTA_MS) +
                  30 * scale(daily, job ? FULL_JOB_LOST_MS : FULL_LOST_MS) + 10 * scale(ratio - MIN_RATIO, 2.5)
          finding(subject, score: score,
            title: "#{label(subject)} got #{Words.times(ratio)} slower",
            summary: "p95 went from #{Words.ms(was)} to #{Words.ms(p95)} over #{Words.count(row['count'])} " \
                     "#{Words.noun(key[1], row['count'])}, #{Words.ms(lost)} lost in all#{moved ? "; #{moved}" : ''}.",
            figures: { "count" => row["count"], "p95" => p95, "p95_before" => was, "ratio" => ratio, "p50" => row["p50(duration)"],
                       "p50_before" => base["p50(duration)"], "count_before" => base["count"], "lost_ms" => lost })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        current = subject_now
        evidence = [
          chart("Latency", scan.chart(source: "transactions", filter: filter, compute: [ "p50(duration)", "p95(duration)" ])),
          phases(current, subject_before),
          by_release(subject),
          markers(subject.app),
          functions(profile_filter(subject.app, [ subject.name ])),
          traces("Slowest in range", filter, order: "-duration")
        ]
        work_detail(finding,
          description: "The comparison is with the same #{subject.work} over the window just before the " \
                       "range, so this is a change, not a habit. A step change usually lines up with a deploy (listed below) " \
                       "or a release in the breakdown; a gradual one with data that grew — a table without an index, a " \
                       "collection loaded whole. The phase table says which part of the time moved, and the profile says " \
                       "which functions now hold more of it than they did.",
          facts: work_facts(subject, current),
          evidence: evidence,
          steps: [
            "Read the phase table: the phase that grew is where to look — database, views, outbound calls, or the app's own code.",
            "If a release or deploy lines up with the change, diff it against the one before and look for new queries, loops or calls in #{subject.name}.",
            "Open the slowest traces (get_trace) and compare their spans with a fast one; for the app's own code, read the functions table.",
            "Done when p95 is back near #{Words.ms(finding.figures['p95_before'])} for the same traffic."
          ])
      end

      private

      # "most of it in the database (+180 ms)"
      sig { params(row: Row, base: Row).returns(T.nilable(String)) }
      def biggest_move(row, base)
        moves = Telemetry::Work::PARTS.reject(&:overlaps).to_h do |part|
          key = "avg(#{part.name})"
          [ part.phrase, row[key].to_f - base[key].to_f ]
        end
        phrase, delta = moves.max_by { |_, change| change }
        return nil if phrase.nil? || delta.to_f < MIN_DELTA_MS / 2

        "the average grew most in #{phrase} (+#{Words.ms(delta)})"
      end
    end
  end
end
