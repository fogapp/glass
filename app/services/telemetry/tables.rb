# typed: strict
# frozen_string_literal: true

module Telemetry
  # The registry of partitioned signal tables: what Partitions creates days
  # for, how long a day is kept by default, and which signal gives up its
  # oldest days first when the disk budget is exceeded.
  #
  # A new partitioned table is one entry here plus its migration.
  module Tables
    extend T::Sig

    class Table < T::Struct
      const :name, String
      # What the console calls it (Settings › Retention).
      const :label, String
      const :retention_days, Integer
      const :max_retention_days, Integer, default: 1100
      # Lower sheds first under disk pressure; nil never sheds — rollups and
      # markers are small and are what long-range charts are drawn from.
      const :shed_order, T.nilable(Integer), default: nil
    end

    ALL = T.let([
      Table.new(name: "transactions", label: "Requests and jobs", retention_days: 30, shed_order: 3),
      Table.new(name: "spans", label: "Trace spans", retention_days: 7, shed_order: 1),
      Table.new(name: "logs", label: "Logs", retention_days: 7, shed_order: 0),
      Table.new(name: "profile_samples", label: "Profiles", retention_days: 14, shed_order: 4),
      Table.new(name: "metric_points", label: "Metrics (10 s)", retention_days: 2, shed_order: 2),
      Table.new(name: "metric_points_5m", label: "Metrics (5 min)", retention_days: 90),
      Table.new(name: "metric_points_1h", label: "Metrics (1 h)", retention_days: 730),
      Table.new(name: "page_events", label: "Visitor events", retention_days: 400, shed_order: 5),
      Table.new(name: "visits", label: "Visits", retention_days: 400),
      # Small, and the only exact record of spend: the last signal to go.
      Table.new(name: "model_calls", label: "Model calls", retention_days: 400, shed_order: 6),
      Table.new(name: "markers", label: "Deploys and events", retention_days: 730)
    ].freeze, T::Array[Table])

    # The dictionaries the signal tables name rows of by id. Not partitioned
    # — a series or a stack outlives any one day — so they are not
    # retention's to drop: Telemetry::Dictionaries prunes what nothing
    # references any more, and their size counts against the disk budget
    # alongside the partitions.
    DICTIONARIES = T.let(%w[metric_series profile_stacks profile_functions].freeze, T::Array[String])

    sig { params(name: String).returns(T.nilable(Table)) }
    def self.find(name) = ALL.find { |table| table.name == name }

    sig { params(name: String).returns(Table) }
    def self.fetch(name) = find(name) || raise(ArgumentError, "unknown telemetry table: #{name}")
  end
end
