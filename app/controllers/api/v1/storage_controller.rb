# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Storage: what telemetry is on disk, by signal and by day,
    # against the budget. The dictionaries count towards what is used, as
    # they do when the budget is enforced.
    class StorageController < BaseController
      sig { void }
      def show
        setting = AppSetting.current
        partitions = Telemetry::Partitions.list
        dictionary_bytes = Telemetry::Dictionaries.bytes
        render json: {
          used_bytes: partitions.sum(&:bytes) + dictionary_bytes, budget_bytes: setting.disk_budget_mb.megabytes,
          dictionary_bytes: dictionary_bytes,
          tables: Telemetry::Tables::ALL.map { |table|
            days = partitions.select { |partition| partition.table == table.name }
            { table: table.name, label: table.label, bytes: days.sum(&:bytes), retention_days: setting.retention_for(table),
              days: days.map { |partition| { day: partition.day.iso8601, bytes: partition.bytes } } }
          }
        }
      end
    end
  end
end
