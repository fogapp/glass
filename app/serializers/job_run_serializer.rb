# typed: strict
# frozen_string_literal: true

# Settings › Background jobs: each managed job and its recent runs.
module JobRunSerializer
  extend T::Sig

  sig { params(definition: ManagedJobs::Definition, runs: T::Array[JobRun]).returns(T::Hash[Symbol, T.untyped]) }
  def self.job_json(definition, runs:)
    { key: definition.key, label: definition.label, description: definition.description, runs: runs.map { |run| run_json(run) } }
  end

  sig { params(run: JobRun).returns(T::Hash[Symbol, T.untyped]) }
  def self.run_json(run)
    {
      id: run.id, job_key: run.job_key, status: run.status, trigger: run.trigger,
      message: run.message, error: run.error,
      started_at: run.started_at, finished_at: run.finished_at, created_at: run.created_at
    }
  end
end
