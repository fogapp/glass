# typed: strict
# frozen_string_literal: true

# Sync/job observability. ApplicationJob#track_run
# wraps a job's work in one (resolve, then execute): queued → running →
# succeeded/failed; a String result becomes the
# human-readable message; errors re-raise so ActiveJob retry still applies
# (a retry flips the same row back to running).
class JobRun < ApplicationRecord
  extend T::Sig

  class Status < T::Enum
    include ApplicationEnum
    enums do
      Queued = new("queued")
      Running = new("running")
      Succeeded = new("succeeded")
      Failed = new("failed")
    end
  end

  class Trigger < T::Enum
    include ApplicationEnum
    enums do
      Manual = new("manual")
      System = new("system")
    end
  end

  belongs_to :household, optional: true

  attribute :status, Status
  attribute :trigger, Trigger

  validates :job_key, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :unfinished, -> { where(status: [ Status::Queued.serialize, Status::Running.serialize ]) }

  class Claim < T::Struct
    const :job_run, JobRun
    # False when a run was already in flight; `job_run` is then that run.
    const :started, T::Boolean
  end

  # The one way a run is started on request — the console's trigger and fog's
  # POST /fog/backup both come here. Under a per-job advisory lock, either
  # adopt the run already in flight (an unfinished row younger than
  # `stale_after`; older ones are presumed orphaned by a dead process) or
  # create a queued row for the caller to enqueue. The lock is
  # transaction-scoped and keyed per job: a double-clicked trigger and a fog
  # trigger contend on one lock, and different jobs never wait on each other.
  sig do
    params(job_key: String, stale_after: ActiveSupport::Duration, trigger: Trigger, household_id: T.nilable(String))
      .returns(Claim)
  end
  def self.claim(job_key:, stale_after:, trigger:, household_id: nil)
    claimed = T.let(nil, T.nilable(Claim))
    transaction do
      connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote("managed_job:#{job_key}")}))")
      active = where(job_key: job_key).unfinished.where(created_at: stale_after.ago..).order(created_at: :desc).first
      claimed =
        if active
          Claim.new(job_run: active, started: false)
        else
          Claim.new(job_run: create!(job_key: job_key, household_id: household_id, trigger: trigger.serialize), started: true)
        end
    end
    T.must(claimed)
  end

  # The row a run should report into: the one it was handed (console
  # trigger, or a retry of an earlier attempt), else a fresh System row.
  sig { params(job_key: String, job_run_id: T.nilable(String)).returns(JobRun) }
  def self.resolve(job_key:, job_run_id: nil)
    existing = job_run_id.present? ? find_by(id: job_run_id) : nil
    existing || create!(job_key: job_key, trigger: Trigger::System.serialize)
  end

  sig { params(block: T.proc.returns(T.nilable(String))).returns(T.nilable(String)) }
  def execute(&block)
    update!(status: Status::Running.serialize, started_at: Time.current, error: nil)
    result = block.call
    update!(status: Status::Succeeded.serialize, finished_at: Time.current,
      message: result.is_a?(String) ? result.truncate(500) : nil)
    result
  rescue StandardError => e
    update!(status: Status::Failed.serialize, finished_at: Time.current,
      error: "#{e.class}: #{e.message}".truncate(2000))
    raise
  end
end
