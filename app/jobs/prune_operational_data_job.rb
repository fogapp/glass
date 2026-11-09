# typed: strict
# frozen_string_literal: true

# Keeps Glass's own operational record from outliving its usefulness.
#
# This is the small, row-by-row half of retention: the activity trail, job
# history and closed incidents in the primary database. Telemetry — the tables that actually
# grow — is never pruned by DELETE; its retention is a partition drop
# (Telemetry::Partitions, MaintainPartitionsJob).
#
# The windows are a judgement about how long each kind of row can still
# answer a question:
#
#   - An error is the forensic record. "Ingest broke in March" is a question
#     people genuinely ask, so errors outlive everything else.
#   - Info and warnings are for reading this week. After three months they
#     are the texture of normal operation, not evidence.
#   - A job run describes one execution; a month is long enough to see a
#     pattern in them.
#   - A closed incident is forensic, like an error: "was it alerting last
#     spring?" is asked, so it is kept as long as errors are — and an open
#     one is never pruned, however old. Nothing else holds an incident's id
#     (activity names it in a payload, triage keys its findings by the
#     monitor), so it goes alone.
class PruneOperationalDataJob < ApplicationJob
  extend T::Sig
  include ManagedJob

  JOB_KEY = "prune_operational_data"
  DESCRIPTION = "Age out Glass's own activity trail, job history and closed incidents past their retention windows."

  # Rows per DELETE. Small enough that each statement is short, large enough
  # that a year of backlog drains in one run rather than one row at a time.
  BATCH = 5_000
  # A backstop, not a policy: if a table is somehow so far behind that it
  # cannot be drained in one night, stop and let the next run continue rather
  # than holding a connection until morning.
  MAX_BATCHES_PER_TABLE = 200

  class Retention < T::Struct
    const :label, String
    const :window, ActiveSupport::Duration
    # Takes the cutoff so the scope can decide what "older than" means for it —
    # job_runs measure it against finishing, everything else against creation.
    const :scope, T.proc.params(cutoff: ActiveSupport::TimeWithZone).returns(T.untyped)
  end

  POLICIES = T.let([
    Retention.new(
      label: "activity", window: 90.days,
      scope: ->(cutoff) {
        ActivityEntry.where(created_at: ...cutoff)
          .where.not(severity: Activity::Severity::Error.serialize)
      }
    ),
    Retention.new(
      label: "activity errors", window: 1.year,
      scope: ->(cutoff) {
        ActivityEntry.where(created_at: ...cutoff)
          .where(severity: Activity::Severity::Error.serialize)
      }
    ),
    Retention.new(
      # Finished only: a queued or running row is either live or orphaned, and
      # ManagedJobs::STALE_AFTER is what decides which. Deleting one out from
      # under a running job would make the console lose track of it.
      label: "job runs", window: 30.days,
      scope: ->(cutoff) { JobRun.where(finished_at: ...cutoff) }
    ),
    Retention.new(
      # Measured from closing: an incident that was open for months is as
      # old as the day it ended.
      label: "closed incidents", window: 1.year,
      scope: ->(cutoff) { Incident.where(closed_at: ...cutoff) }
    )
  ].freeze, T::Array[Retention])

  queue_as :default
  # Batched deletes over every operational table; a first run after a long
  # gap has a lot to age out.
  limits_concurrency key: JOB_KEY, duration: 30.minutes

  sig { override.returns(T.nilable(String)) }
  def run_job
    now = Time.current
    deleted = POLICIES.to_h { |policy| [ policy.label, prune(policy, now: now) ] }
    total = deleted.values.sum

    return "nothing to prune" if total.zero?

    Activity.record(source: "maintenance", event: "prune.completed",
      summary: "Pruned #{total} operational #{'row'.pluralize(total)}: " \
               "#{deleted.reject { |_, count| count.zero? }.map { |label, count| "#{count} #{label}" }.join(', ')}",
      payload: deleted)

    "#{total} #{'row'.pluralize(total)} pruned"
  end

  private

  # `where(id: ... limit)` rather than `scope.limit(n).delete_all`, which
  # Postgres will not accept — DELETE takes no LIMIT, so the bound has to ride
  # in on a subselect.
  sig { params(policy: Retention, now: ActiveSupport::TimeWithZone).returns(Integer) }
  def prune(policy, now:)
    scope = policy.scope.call(now - policy.window)
    model = scope.model
    BatchedDelete.run(batch: BATCH, max_batches: MAX_BATCHES_PER_TABLE) do |limit|
      model.where(id: scope.limit(limit).select(:id)).delete_all
    end
  end
end
