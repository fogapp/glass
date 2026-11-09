# typed: strict
# frozen_string_literal: true

# Every minute: every enabled monitor, each on its own (one failing query
# must not stop the rest), sharing one Query::Context per household.
class EvaluateMonitorsJob < ApplicationJob
  extend T::Sig
  include ManagedJob

  JOB_KEY = "evaluate_monitors"
  DESCRIPTION = "Evaluate every enabled monitor and open or close incidents."

  queue_as :monitor
  limits_concurrency key: JOB_KEY, duration: 5.minutes

  sig { override.returns(T.nilable(String)) }
  def run_job
    now = Time.now.utc
    alerting = T.let(0, Integer)
    monitors = MonitorRule.unscoped.enabled.includes(:household).to_a
    # One context per household: building one reads every app it has.
    contexts = T.let({}, T::Hash[String, Query::Context])
    monitors.each do |monitor|
      context = contexts[monitor.household_id] ||= Query::Context.new(T.must(monitor.household))
      Monitors::Evaluator.call(monitor, now: now, context: context)
      alerting += 1 if monitor.state_enum == MonitorRule::State::Alert
    rescue StandardError => e
      monitor.update_columns(last_error: "#{e.class}: #{e.message}".truncate(500), last_evaluated_at: now) # rubocop:disable Rails/SkipsModelValidations
      Activity.record(source: "monitors", event: "monitor.failed", severity: Activity::Severity::Error,
        summary: "#{monitor.name} could not be evaluated: #{e.message}", subject: monitor, exception: e)
    end
    "#{monitors.size} evaluated, #{alerting} alerting"
  end
end
