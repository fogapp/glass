# typed: strict
# frozen_string_literal: true

# Folds closed 10-second metric windows into the 5-minute and hourly tiers
# (Telemetry::Rollup). The raw tier is kept two days; everything older is
# drawn from these.
class RollupMetricsJob < ApplicationJob
  extend T::Sig
  include ManagedJob

  JOB_KEY = "rollup_metrics"
  DESCRIPTION = "Fold finished metric windows into the 5-minute and hourly tiers that long-range charts read."

  queue_as :rollup
  limits_concurrency key: JOB_KEY, duration: 10.minutes

  sig { override.returns(T.nilable(String)) }
  def run_job
    written = Telemetry::Rollup.run!
    written.map { |tier, rows| "#{rows} #{tier}" }.join(", ")
  end
end
