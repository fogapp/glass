# typed: strict
# frozen_string_literal: true

# Releases concurrency semaphores whose holder no longer exists.
#
# Every scheduled job here holds a semaphore so a second copy cannot start
# against the same work: minutes for the rollup, partition, monitor and fog
# jobs, half an hour for the prune, two hours for ProduceBackupJob (a
# pg_dump of the primary database). The cost of that choice appears when a
# worker dies without releasing: nothing clears the semaphore until its
# duration runs out, so a backup killed by a restart or a power loss would
# block its own re-run for up to two hours.
#
# A semaphore is orphaned when no unfinished, un-failed job carries its
# concurrency key. Failed jobs count as non-holders: they sit in
# failed_executions awaiting a decision, and blocking re-enqueues on their
# behalf is the lockout this job exists to end. Normal completion — success
# or a handled failure — releases semaphores through Solid Queue itself, so
# in a healthy system this job finds nothing.
class ReclaimOrphanedSemaphoresJob < ApplicationJob
  extend T::Sig

  DESCRIPTION = "Release concurrency semaphores left behind by jobs that died without finishing."

  queue_as :default
  limits_concurrency key: "reclaim_orphaned_semaphores", duration: 5.minutes

  sig { void }
  def perform
    held = SolidQueue::Job.where(finished_at: nil)
      .where.not(concurrency_key: nil)
      .where.not(id: SolidQueue::FailedExecution.select(:job_id))
      .select(:concurrency_key)

    released = SolidQueue::Semaphore.where.not(key: held).delete_all
    return if released.zero?

    # Warn, not info: every reclaim here means a job died hard enough to skip
    # its own cleanup, and someone should know that happened.
    Activity.record(source: "jobs", event: "semaphores.reclaimed",
      severity: Activity::Severity::Warn,
      summary: "Released #{released} orphaned concurrency #{'semaphore'.pluralize(released)} " \
               "left behind by jobs that died without finishing")
  end
end
