# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # A job that waits in its queue far longer than the work on that queue
    # takes to run: too few workers, a queue shared with something slow, a
    # burst it cannot drain — or workers held by jobs that never finished
    # (Stuck says which). A queue that runs a few at a time on purpose makes
    # a burst wait a few runs' worth; that is the design working, not a
    # finding.
    class QueueWait < WorkDetector
      MIN_COUNT = 5
      # Waiting less than this is never worth a look, however quick the
      # queue's work.
      MIN_WAIT_MS = 600_000.0
      # How many of the queue's own p95 runs a wait must exceed: a burst on
      # a narrow queue waits a run or two by design.
      RUNS = 4

      sig { override.returns(Kind) }
      def self.kind = Kind::Queue

      sig { override.returns(T::Array[Finding]) }
      def findings
        prior = before
        queues = queue_of
        runs = queue_runs
        now.filter_map do |key, row|
          next unless key[1] == "job"

          wait = row["p95(queue_ms)"].to_f
          was = prior[key]&.dig("p95(queue_ms)")
          queue = queues[[ key[0], key[2] ]]
          run = runs[[ key[0], queue ]] || row["p95(duration)"].to_f
          next if row["count"].to_f < MIN_COUNT || wait < [ MIN_WAIT_MS, RUNS * run ].max
          # Better than before is not a problem that appeared.
          next if was && wait <= was.to_f

          subject = work_subject(key)
          score = 30 + 30 * scale(wait, 7_200_000.0) + (was && wait > was.to_f * 2 ? 10 : 0)
          finding(subject, score: score,
            title: "#{label(subject)} waits #{Words.ms(wait)} to start",
            summary: "At p95, #{Words.count(row['count'])} job runs spent #{Words.ms(wait)} queued before they began" \
                     "#{was ? ", against #{Words.ms(was)} before" : ''}; the work on #{queue ? "the #{queue} queue" : 'its queue'} " \
                     "runs for #{Words.ms(run)} at p95.",
            figures: { "count" => row["count"], "queue_p95" => wait, "queue_p95_before" => was, "p50" => row["p50(duration)"],
                       "queue" => queue, "queue_run_p95" => run })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        current = subject_now
        queue = scan.list(source: "transactions", filter: filter, limit: 1).first&.dig("queue")
        neighbours = queue && scan.table(source: "transactions", group_by: %w[name], filter: scan.filter("kind:job", Query::Filter.quote("queue", queue)),
          compute: [ "count", "sum(duration)", "p95(queue_ms)" ], limit: 10)
        evidence = [
          chart("Queue wait and runs", scan.chart(source: "transactions", filter: filter, compute: [ "p95(queue_ms)", "count" ])),
          (neighbours ? table("Everything on the #{queue} queue", [ column("name", "Job"), column("count", "Runs"),
            column("sum(duration)", "Time running", "ms"), column("p95(queue_ms)", "p95 wait", "ms") ], neighbours,
            note: "A job that runs long on a shared queue makes everything behind it wait.") : nil),
          traces("Longest waits", filter, order: "-queue_ms")
        ]
        work_detail(finding,
          description: "The time is not spent running — the job sat in its queue until a worker was free, for far " \
                       "longer than the work on its queue takes to run. If a job on the queue has stopped finishing (a " \
                       "\"never finished\" finding), it holds the workers and that is the fix. Otherwise it " \
                       "is a capacity or scheduling problem, not a slow job: too few worker threads for the queue, a " \
                       "long-running job sharing the queue, or a burst enqueued at once. The table shows what else runs on " \
                       "the same queue and how long it holds a worker.",
          facts: work_facts(subject, current) + [ fact("Queue", queue) ].compact,
          evidence: evidence,
          steps: [
            "Read what else runs on the queue: move a long-running job to a queue of its own if it holds the workers.",
            "Check the worker's queue configuration and thread count against how many jobs arrive at peak.",
            "If jobs arrive in bursts, spread them (staggered schedules, batching) rather than adding workers.",
            "Done when the p95 queue wait is well under the time the job takes to run."
          ])
      end

      private

      # The queue each job runs on, by app and name: the one most of its
      # runs came from.
      sig { returns(T::Hash[[ T.untyped, T.untyped ], T.untyped]) }
      def queue_of
        rows = scan.table(source: "transactions", group_by: %w[app queue name], compute: %w[count], filter: scan.filter("kind:job"))
        rows.sort_by { |row| -row["count"].to_f }.each_with_object({}) do |row, queues|
          queues[[ row["app"], row["name"] ]] ||= row["queue"]
        end
      end

      # How long the work on each queue takes, by app and queue: the yardstick
      # a wait is measured against.
      sig { returns(T::Hash[[ T.untyped, T.untyped ], Float]) }
      def queue_runs
        rows = scan.table(source: "transactions", group_by: %w[app queue], compute: [ "p95(duration)" ], filter: scan.filter("kind:job"))
        rows.to_h { |row| [ [ row["app"], row["queue"] ], row["p95(duration)"].to_f ] }
      end
    end
  end
end
