# typed: strict
# frozen_string_literal: true

# A job ManagedJobs lists: the console can trigger it and shows its history.
# The including class declares JOB_KEY (and DESCRIPTION, for the registry
# and config/recurring.yml) and defines `run_job`; this supplies `perform`,
# which takes the JobRun id an enqueue hands it and runs the body inside
# track_run, so every managed job resolves the row the console created.
#
# `run_job` returns the run's one-line summary (nil for none). A body that
# reports onto its run as it goes (ProduceBackupJob) reads it as `job_run`.
module ManagedJob
  extend T::Sig
  extend T::Helpers

  abstract!
  requires_ancestor { ApplicationJob }

  sig { params(job_run_id: T.nilable(String)).void }
  def perform(job_run_id = nil)
    # rubocop:disable Sorbet/ConstantsFromStrings -- a fixed constant name on a job class, not a string from input
    job_key = T.cast(self.class.const_get(:JOB_KEY, false), String)
    # rubocop:enable Sorbet/ConstantsFromStrings
    track_run(job_key: job_key, job_run_id: job_run_id) do |run|
      @job_run = T.let(run, T.nilable(JobRun))
      run_job
    end
  end

  sig { abstract.returns(T.nilable(String)) }
  def run_job; end

  private

  # The run this perform is tracked as; only valid inside run_job.
  sig { returns(JobRun) }
  def job_run = T.must(@job_run)
end
