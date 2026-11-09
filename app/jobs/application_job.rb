# typed: strict
# frozen_string_literal: true

# Base job:
# - polynomial retry as the baseline; a subclass's own retry_on takes
#   precedence (most-recently-registered handler wins in ActiveJob);
# - trace_id propagation so one causal episode threads request → jobs →
#   activity entries;
# - after_discard: only *permanent* failures (retries exhausted or discarded)
#   record an error-severity activity entry — intermediate retries stay quiet.
class ApplicationJob < ActiveJob::Base
  extend T::Sig

  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  retry_on ActiveRecord::Deadlocked
  discard_on ActiveJob::DeserializationError
  # A validation failure is a verdict, not a blip — the same write against
  # the same record fails the same way, so retrying re-runs the job's full
  # cost (a whole reconcile walk, a backup) twice more to report one bug,
  # and delays the dead-letter signal by the cumulative backoff.
  # Deliberately narrow: NotFound and nil errors can be enqueue/commit races
  # that a later attempt genuinely wins, so those keep the blanket retry.
  discard_on ActiveRecord::RecordInvalid
  discard_on ActiveRecord::RecordNotSaved

  after_discard do |job, error|
    Activity.record(
      source: "jobs",
      event: "job.dead",
      severity: Activity::Severity::Error,
      summary: "#{job.class.name} permanently failed: #{error.class}: #{error.message.to_s.truncate(200)}",
      payload: { job_class: job.class.name, job_id: job.job_id, queue: job.queue_name }
    )
  end

  # The trace this job was enqueued under (nil when it was performed without
  # being deserialized, e.g. perform_now); around_perform continues it.
  sig { returns(T.nilable(String)) }
  attr_reader :glass_trace_id

  sig { returns(T::Hash[String, T.untyped]) }
  def serialize
    super.merge("glass_trace_id" => Current.trace_id, "glass_job_run_id" => @glass_job_run_id)
  end

  sig { params(job_data: T::Hash[String, T.untyped]).void }
  def deserialize(job_data)
    super
    @glass_trace_id = T.let(job_data["glass_trace_id"], T.nilable(String))
    @glass_job_run_id = T.let(job_data["glass_job_run_id"], T.nilable(String))
  end

  # The job's JobRun, with attempt continuity: the first attempt creates the row,
  # a retry re-serializes the job carrying its id, and the same row flips
  # back to running — the model's "a retry flips the same row" promise held
  # only for ids passed in explicitly; a fetch that failed twice then
  # succeeded used to read as three separate runs in the console.
  #
  # The block is given the run; ManagedJob (which every registered job
  # includes) keeps it as `job_run` for a body that reports onto it.
  sig do
    params(job_key: String, job_run_id: T.nilable(String),
      block: T.proc.params(run: JobRun).returns(T.nilable(String))).returns(T.nilable(String))
  end
  def track_run(job_key:, job_run_id: nil, &block)
    run = JobRun.resolve(job_key: job_key, job_run_id: job_run_id || @glass_job_run_id)
    @glass_job_run_id = T.let(run.id, T.nilable(String))
    run.execute { block.call(run) }
  end

  around_perform do |job, block|
    trace = job.glass_trace_id || SecureRandom.uuid
    Current.set(trace_id: trace) { block.call }
  end
end
