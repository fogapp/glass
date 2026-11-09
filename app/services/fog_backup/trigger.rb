# typed: strict
# frozen_string_literal: true

module FogBackup
  # Starts (or adopts) the producer job for fog's POST /fog/backup.
  #
  # Claims through ManagedJobs.claim!, the console trigger's own path, so a
  # fog trigger and a console trigger can never double-enqueue — they contend
  # on one lock and see each other's unfinished runs. Unlike
  # ManagedJobs.trigger! this works with no household (a fresh instance being
  # backed up before setup) and answers the Claim rather than nil, because
  # fog's contract answer to "already producing" is 409 + that job's id.
  module Trigger
    extend T::Sig

    sig { params(household: T.nilable(Household)).returns(JobRun::Claim) }
    def self.call(household: nil)
      ManagedJobs.claim!(definition: T.must(ManagedJobs.find(ProduceBackupJob::JOB_KEY)),
        household: household, trigger: JobRun::Trigger::System)
    end
  end
end
