# typed: strict
# frozen_string_literal: true

# Registry of jobs the console can trigger and show history for.
# Each definition names its job class;
# the key (JOB_KEY) and the description (DESCRIPTION) are read from it, and
# config/recurring.yml reads the same DESCRIPTION, so the schedule, the
# registry and the jobs can't drift.
module ManagedJobs
  extend T::Sig

  # A queued/running row older than this is presumed orphaned by a dead
  # process, so it stops blocking manual triggers. Jobs
  # whose honest runtime exceeds it say so per-definition below.
  STALE_AFTER = T.let(15.minutes, ActiveSupport::Duration)

  # Every enqueue must hand job_run.id to the job it enqueues, and the job
  # must pass it through to track_run. The row the console created IS the
  # row the run resolves — an ignored job_run leaves a Manual row queued
  # forever: it blocks re-triggers for stale_after, shows a phantom run beside
  # the real one, and (finished_at forever NULL) is unprunable. The default
  # enqueue, `job.perform_later(job_run.id)`, does; `enqueue` overrides it
  # only where the console should start something else.
  class Definition < T::Struct
    extend T::Sig

    const :job, T.class_of(ApplicationJob)
    const :label, String
    const :enqueue, T.nilable(T.proc.params(household: T.nilable(Household), job_run: JobRun).void), default: nil
    const :stale_after, ActiveSupport::Duration, default: STALE_AFTER

    # JOB_KEY and DESCRIPTION are the managed-job contract every job class
    # here declares; ManagedJobs' spec resolves both for each definition.
    # rubocop:disable Sorbet/ConstantsFromStrings -- a fixed constant name on a job class, not a string from input
    sig { returns(String) }
    def key = T.cast(job.const_get(:JOB_KEY, false), String)

    sig { returns(String) }
    def description = T.cast(job.const_get(:DESCRIPTION, false), String)
    # rubocop:enable Sorbet/ConstantsFromStrings

    sig { params(household: T.nilable(Household), job_run: JobRun).void }
    def enqueue!(household, job_run)
      custom = enqueue
      custom ? custom.call(household, job_run) : job.perform_later(job_run.id)
    end
  end

  ALL = T.let([
    Definition.new(job: MaintainPartitionsJob, label: "Maintain telemetry partitions"),
    Definition.new(job: RollupMetricsJob, label: "Roll up metrics"),
    Definition.new(job: EvaluateMonitorsJob, label: "Evaluate monitors"),
    Definition.new(job: FogSyncJob, label: "Sync with fog"),
    Definition.new(job: PruneOperationalDataJob, label: "Prune operational data"),
    Definition.new(
      job: ProduceBackupJob, label: "Produce backup artifact",
      # Dumping takes as long as it takes; presuming it dead at minute
      # sixteen would let a duplicate dump queue up.
      stale_after: 2.hours
    )
  ].freeze, T::Array[Definition])

  sig { params(key: String).returns(T.nilable(Definition)) }
  def self.find(key) = ALL.find { |definition| definition.key == key }

  # The one way to manually trigger a managed job — console and MCP both call
  # this. Returns the created JobRun, or nil when the job is already running.
  sig { params(definition: Definition, household: Household).returns(T.nilable(JobRun)) }
  def self.trigger!(definition:, household:)
    claim = claim!(definition: definition, household: household, trigger: JobRun::Trigger::Manual)
    claim.job_run if claim.started
  end

  # Claim a run and enqueue it if this call started it — the one path every
  # trigger takes (the console's trigger! and fog's FogBackup::Trigger), so
  # they contend on one lock (JobRun.claim makes check-and-create one step)
  # and can never double-enqueue. The Claim says which happened: started, or
  # the run already in flight. The household is nil for a trigger that has
  # none (a fresh instance backed up before setup).
  sig do
    params(definition: Definition, household: T.nilable(Household), trigger: JobRun::Trigger).returns(JobRun::Claim)
  end
  def self.claim!(definition:, household:, trigger:)
    claim = JobRun.claim(job_key: definition.key, stale_after: definition.stale_after,
      trigger: trigger, household_id: household&.id)
    definition.enqueue!(household, claim.job_run) if claim.started
    claim
  end
end
