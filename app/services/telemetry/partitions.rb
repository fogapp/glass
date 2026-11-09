# typed: strict
# frozen_string_literal: true

module Telemetry
  # Day partitions for the signal tables: created ahead of need, dropped
  # when they expire. This is the whole of telemetry retention — a DROP
  # TABLE is instant and returns its disk at once, where a DELETE of the
  # same rows would bloat the table it was meant to shrink.
  #
  # Days are UTC. A partition is named <table>_pYYYYMMDD and holds
  # [that day 00:00Z, next day 00:00Z).
  module Partitions
    extend T::Sig

    # Yesterday through the day after tomorrow: late records from a box
    # that was asleep, and a margin so a missed maintenance run is never a
    # day without partitions.
    DAYS_BEHIND = 2
    DAYS_AHEAD = 2

    class Partition < T::Struct
      const :table, String
      const :name, String
      const :day, Date
      const :bytes, Integer
    end

    sig { params(today: Date).returns(Integer) }
    def self.ensure!(today: Time.now.utc.to_date)
      days = ((today - DAYS_BEHIND)..(today + DAYS_AHEAD)).to_a
      create_missing(Tables::ALL.flat_map { |table| days.map { |day| [ table.name, day ] } })
    end

    # Create the partition holding `time` in each named table, if missing —
    # ingest's answer to "no partition of relation found for row".
    sig { params(tables: T::Array[String], time: T.any(Time, ActiveSupport::TimeWithZone)).void }
    def self.ensure_for!(tables, time)
      day = time.utc.to_date
      create_missing(tables.map { |name| [ Tables.fetch(name).name, day ] })
    end

    # Drop every partition whose whole day is older than its table's
    # retention. Returns what was dropped. `partitions` is a `list` the
    # caller already read, so one maintenance run sizes the tables once.
    sig { params(today: Date, setting: AppSetting, partitions: T::Array[Partition]).returns(T::Array[Partition]) }
    def self.drop_expired!(today: Time.now.utc.to_date, setting: AppSetting.current, partitions: list)
      dropped = partitions.select do |partition|
        keep_days = setting.retention_for(Tables.fetch(partition.table))
        partition.day < today - keep_days
      end
      dropped.each { |partition| drop(partition) }
      dropped
    end

    # Over the disk budget, shed the oldest day of the most expendable
    # signal that still has more than today to give, until under it.
    # `fixed_bytes` is what counts against the budget but is never shed —
    # the dictionaries (Tables::DICTIONARIES).
    sig do
      params(budget_bytes: Integer, today: Date, partitions: T::Array[Partition], fixed_bytes: Integer)
        .returns(T::Array[Partition])
    end
    def self.shed_to_budget!(budget_bytes:, today: Time.now.utc.to_date, partitions: list, fixed_bytes: Dictionaries.bytes)
      shed = T.let([], T::Array[Partition])
      partitions = partitions.dup
      total = partitions.sum(&:bytes) + fixed_bytes

      while total > budget_bytes
        victim = next_to_shed(partitions, today)
        break if victim.nil?

        drop(victim)
        partitions.delete(victim)
        shed << victim
        total -= victim.bytes
      end
      shed
    end

    sig { returns(T::Array[Partition]) }
    def self.list
      known = Tables::ALL.map(&:name)
      rows = connection.select_rows(<<~SQL.squish)
        SELECT parent.relname, child.relname, pg_total_relation_size(child.oid)
        FROM pg_inherits
        JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
        JOIN pg_class child ON child.oid = pg_inherits.inhrelid
        JOIN pg_namespace ns ON ns.oid = parent.relnamespace
        WHERE ns.nspname = current_schema()
        ORDER BY child.relname
      SQL
      rows.filter_map do |table, name, bytes|
        next unless known.include?(table)

        day = day_of(name.to_s)
        Partition.new(table: table.to_s, name: name.to_s, day: day, bytes: bytes.to_i) if day
      end
    end

    # Everything telemetry holds against the budget: the partitions and the
    # dictionaries they name rows of.
    sig { returns(Integer) }
    def self.total_bytes = list.sum(&:bytes) + Dictionaries.bytes

    sig { params(table: String, day: Date).returns(String) }
    def self.partition_name(table, day) = "#{table}_p#{day.strftime('%Y%m%d')}"

    # Create whichever of the (table, day) partitions do not exist yet,
    # after one look at the ones that do. Returns how many were created.
    sig { params(wanted: T::Array[[ String, Date ]]).returns(Integer) }
    def self.create_missing(wanted)
      existing = existing_names
      missing = wanted.reject { |table, day| existing.include?(partition_name(table, day)) }
      missing.each { |table, day| create(table, day) }
      missing.size
    end
    private_class_method :create_missing

    # Every partition's name, without the sizes `list` pays for.
    sig { returns(T::Set[String]) }
    def self.existing_names
      connection.select_values(<<~SQL.squish).to_set
        SELECT child.relname
        FROM pg_inherits
        JOIN pg_class child ON child.oid = pg_inherits.inhrelid
        JOIN pg_namespace ns ON ns.oid = child.relnamespace
        WHERE ns.nspname = current_schema()
      SQL
    end
    private_class_method :existing_names

    # Identifiers come from the Tables registry and a Date, never from
    # input, and are quoted anyway. IF NOT EXISTS covers another process
    # creating the same day in between.
    sig { params(table: String, day: Date).void }
    def self.create(table, day)
      name = partition_name(table, day)
      connection.execute(<<~SQL.squish)
        CREATE TABLE IF NOT EXISTS #{connection.quote_table_name(name)}
        PARTITION OF #{connection.quote_table_name(table)}
        FOR VALUES FROM (#{connection.quote("#{day.iso8601} 00:00:00+00")})
        TO (#{connection.quote("#{(day + 1).iso8601} 00:00:00+00")})
      SQL
    end
    private_class_method :create

    sig { params(partition: Partition).void }
    def self.drop(partition)
      connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name(partition.name)}")
    end
    private_class_method :drop

    sig { params(partitions: T::Array[Partition], today: Date).returns(T.nilable(Partition)) }
    def self.next_to_shed(partitions, today)
      Tables::ALL.select(&:shed_order).sort_by { |table| T.must(table.shed_order) }.each do |table|
        candidates = partitions.select { |p| p.table == table.name && p.day < today && p.bytes.positive? }
        oldest = candidates.min_by(&:day)
        return oldest if oldest
      end
      nil
    end
    private_class_method :next_to_shed

    sig { params(name: String).returns(T.nilable(Date)) }
    def self.day_of(name)
      match = name.match(/_p(\d{4})(\d{2})(\d{2})\z/)
      match && Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
    rescue Date::Error
      nil
    end
    private_class_method :day_of

    sig { returns(ActiveRecord::ConnectionAdapters::AbstractAdapter) }
    def self.connection = TelemetryRecord.connection
    private_class_method :connection
  end
end
