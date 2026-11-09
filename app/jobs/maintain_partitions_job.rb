# typed: strict
# frozen_string_literal: true

# Telemetry's upkeep: make the days ahead, prune the
# dictionaries of what nothing names any more (once a day), drop the days that have
# expired, and — if the telemetry database is over its disk budget — shed
# the oldest days of the most expendable signal until it is not. Says what
# it dropped: shedding is a decision someone should be able to read about
# afterwards.
#
# The dictionaries are pruned before anything is dropped: Telemetry::
# Dictionaries explains why that order is what keeps an id cached by a
# web process from being deleted under it.
class MaintainPartitionsJob < ApplicationJob
  extend T::Sig
  include ManagedJob

  JOB_KEY = "maintain_partitions"
  DESCRIPTION = "Create upcoming telemetry partitions, prune unused series and stacks, drop expired days, and enforce the disk budget."

  # A process that has said nothing for this long is gone, not quiet.
  FORGET_PROCESSES_AFTER = T.let(7.days, ActiveSupport::Duration)

  queue_as :rollup
  limits_concurrency key: JOB_KEY, duration: 10.minutes

  sig { override.returns(T.nilable(String)) }
  def run_job
    setting = AppSetting.current
    created = Telemetry::Partitions.ensure!
    partitions = Telemetry::Partitions.list
    pruned = Telemetry::Dictionaries.prune_if_due!(setting: setting).values.sum
    expired = Telemetry::Partitions.drop_expired!(setting: setting, partitions: partitions)
    dropped = expired.to_set(&:name)
    shed = Telemetry::Partitions.shed_to_budget!(budget_bytes: setting.disk_budget_mb.megabytes,
      partitions: partitions.reject { |partition| dropped.include?(partition.name) })
    Telemetry::AgentProcess.where(last_seen_at: ...FORGET_PROCESSES_AFTER.ago).delete_all

    record_shed(shed, setting) if shed.any?
    "#{created} created, #{pruned} pruned, #{expired.size} expired, #{shed.size} shed"
  end

  private

  sig { params(shed: T::Array[Telemetry::Partitions::Partition], setting: AppSetting).void }
  def record_shed(shed, setting)
    bytes = shed.sum(&:bytes)
    Activity.record(
      source: "maintenance", event: "telemetry.shed", severity: Activity::Severity::Warn,
      summary: "Telemetry was over its #{setting.disk_budget_mb} MB budget: dropped " \
               "#{shed.size} #{'day'.pluralize(shed.size)} early (#{ActiveSupport::NumberHelper.number_to_human_size(bytes)})",
      payload: { partitions: shed.map(&:name) }
    )
  end
end
