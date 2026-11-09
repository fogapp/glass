# typed: strict
# frozen_string_literal: true

module Telemetry
  # Pruning the dictionaries (Tables::DICTIONARIES): metric series, profile
  # stacks and profile functions. Signal rows name them by id and are
  # dropped a day at a time; the dictionaries are not partitioned, so
  # without this they keep every series anyone ever tagged and every stack
  # any release ever had — and a release that moves a file is a new set of
  # stacks.
  #
  # A row goes when nothing that is still kept could name it:
  #
  #   - a series whose last point (last_seen_at, stamped by Rollup) is older
  #     than the longest any tier of points is kept, and which has no raw
  #     point waiting to be rolled;
  #   - a stack no profile sample names;
  #   - a function no remaining stack names.
  #
  # Ingest remembers ids per process (Ingest::SeriesResolver,
  # Ingest::ProfileStore), in web workers as much as here, and a deleted id
  # one of them still held would be written into new rows that point at
  # nothing. What keeps that from happening:
  #
  #   1. Those caches forget everything after CACHE_TTL, so every id a
  #      process holds was looked up, or created, within the hour — and the
  #      batch that did so wrote rows naming it (points, samples, stacks).
  #   2. MaintainPartitionsJob prunes *before* it drops or sheds a single
  #      partition, and runs hourly — no more often than CACHE_TTL — so the
  #      rows written in the last hour are all still there to be seen, and
  #      anything a process holds is referenced, and kept. It prunes in at
  #      most one of those runs a day (prune_if_due!): the scans below read
  #      every sample and every stack, and a day's dead rows are no hurry.
  #      Pruning less often than CACHE_TTL is always safe; only more often
  #      is not.
  #   3. What remains is a race: a row unreferenced for the whole retention
  #      window that turns up again in the seconds between this pass reading
  #      and deleting it (or, after a run asked for by hand inside the hour,
  #      one whose last rows that run shed early). Readers already tolerate a missing dictionary row
  #      (a flamegraph files the stack under "(other)", a query never sees
  #      a point without its series), the caches lose the dead id within
  #      the hour and recreate it (ON CONFLICT on the content key), and the
  #      orphaned rows age out with their partition.
  module Dictionaries
    extend T::Sig

    # How long Ingest's caches may hold an id; see (1) above. Never longer
    # than the maintenance interval (config/recurring.yml).
    CACHE_TTL = T.let(1.hour, ActiveSupport::Duration)

    # Rows per DELETE, and a backstop on how many statements one pass makes.
    # The rest waits for the next run.
    BATCH = 5_000
    MAX_BATCHES = 200

    # The point tiers that name a series.
    POINT_TABLES = T.let(%w[metric_points metric_points_5m metric_points_1h].freeze, T::Array[String])

    # Where the last pass is remembered (Telemetry::Cursor).
    CURSOR = "dictionaries:prune"

    # prune! unless a pass already ran this UTC day; nothing pruned if not.
    sig { params(setting: AppSetting, now: Time).returns(T::Hash[String, Integer]) }
    def self.prune_if_due!(setting: AppSetting.current, now: Time.now.utc)
      last = Cursor.position(CURSOR)
      return {} if last && last.utc.to_date >= now.utc.to_date

      pruned = prune!(setting: setting, now: now)
      Cursor.advance!(CURSOR, now)
      pruned
    end

    # Rows deleted, per dictionary.
    sig { params(setting: AppSetting, now: Time).returns(T::Hash[String, Integer]) }
    def self.prune!(setting: AppSetting.current, now: Time.now.utc)
      TelemetryRecord.connection_pool.with_connection do |connection|
        series = prune_series(connection, series_cutoff(setting, now))
        stacks = prune_stacks(connection)
        functions = prune_functions(connection)
        { "metric_series" => series, "profile_stacks" => stacks, "profile_functions" => functions }
      end
    end

    # A series last seen before this has no point left in any tier: the
    # longest any of them is kept, plus the day a partition is kept past
    # its retention (a day is dropped once it is wholly older).
    sig { params(setting: AppSetting, now: Time).returns(Time) }
    def self.series_cutoff(setting, now)
      longest = POINT_TABLES.map { |name| setting.retention_for(Tables.fetch(name)) }.max || 0
      now.advance(days: -(longest + 1))
    end

    # What the dictionaries take on disk — counted against the budget,
    # never shed.
    sig { returns(Integer) }
    def self.bytes
      TelemetryRecord.connection.select_value(TelemetryRecord.sanitize_sql_array([ <<~SQL.squish, Tables::DICTIONARIES ])).to_i
        SELECT coalesce(sum(pg_total_relation_size(c.oid)), 0)
        FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = current_schema() AND c.relkind = 'r' AND c.relname IN (?)
      SQL
    end

    # The raw tier is checked as well as last_seen_at: a series written in
    # the minutes before Rollup stamps it, or while the rollup worker is
    # stopped, has points but an old stamp. metric_points is kept briefly
    # and indexed on series_id, so this is a few index probes a row.
    sig { params(connection: ActiveRecord::ConnectionAdapters::AbstractAdapter, cutoff: Time).returns(Integer) }
    def self.prune_series(connection, cutoff)
      sql = TelemetryRecord.sanitize_sql_array([ <<~SQL.squish, { cutoff: cutoff, batch: BATCH } ])
        DELETE FROM metric_series WHERE id IN (
          SELECT s.id FROM metric_series s
          WHERE s.last_seen_at < :cutoff
            AND NOT EXISTS (SELECT 1 FROM metric_points p WHERE p.series_id = s.id)
          ORDER BY s.id LIMIT :batch)
      SQL
      BatchedDelete.run(batch: BATCH, max_batches: MAX_BATCHES) { connection.exec_delete(sql) }
    end
    private_class_method :prune_series

    # profile_samples has no index on stack_id (it would cost every sample
    # row for a daily question), so "named by no sample" is answered once,
    # by a single hash anti-join over the samples into a scratch table, and
    # the deletes then walk that table by id: each statement short, none
    # rescanning the samples.
    sig { params(connection: ActiveRecord::ConnectionAdapters::AbstractAdapter).returns(Integer) }
    def self.prune_stacks(connection)
      with_candidates(connection, "glass_prune_stacks", <<~SQL.squish) { |scratch| delete_listed(connection, "profile_stacks", scratch) }
        SELECT s.id FROM profile_stacks s
        WHERE NOT EXISTS (SELECT 1 FROM profile_samples p WHERE p.stack_id = s.id)
      SQL
    end
    private_class_method :prune_stacks

    # A stack names its functions in an array, so the functions in use are
    # the stacks' frames unnested — again one pass, after the stacks that
    # went have gone.
    sig { params(connection: ActiveRecord::ConnectionAdapters::AbstractAdapter).returns(Integer) }
    def self.prune_functions(connection)
      with_candidates(connection, "glass_prune_functions", <<~SQL.squish) { |scratch| delete_listed(connection, "profile_functions", scratch) }
        SELECT f.id FROM profile_functions f
        WHERE NOT EXISTS (
          SELECT 1 FROM (SELECT unnest(frames) AS id FROM profile_stacks) used WHERE used.id = f.id)
      SQL
    end
    private_class_method :prune_functions

    # A session temp table on the one connection this pass holds; dropped
    # however the block ends.
    sig do
      params(connection: ActiveRecord::ConnectionAdapters::AbstractAdapter, scratch: String, select: String,
        blk: T.proc.params(scratch: String).returns(Integer)).returns(Integer)
    end
    def self.with_candidates(connection, scratch, select, &blk)
      connection.execute("DROP TABLE IF EXISTS pg_temp.#{scratch}")
      connection.execute("CREATE TEMP TABLE #{scratch} AS #{select}")
      connection.execute("ALTER TABLE pg_temp.#{scratch} ADD PRIMARY KEY (id)")
      yield scratch
    ensure
      connection.execute("DROP TABLE IF EXISTS pg_temp.#{scratch}")
    end
    private_class_method :with_candidates

    sig { params(connection: ActiveRecord::ConnectionAdapters::AbstractAdapter, table: String, scratch: String).returns(Integer) }
    def self.delete_listed(connection, table, scratch)
      after = T.let(0, Integer)
      deleted = T.let(0, Integer)
      # A batch is as long as the ids it listed: a row already gone is still
      # one walked past, so the walk ends on a short list, not a short delete.
      BatchedDelete.run(batch: BATCH, max_batches: MAX_BATCHES) do |limit|
        ids = connection.select_values(TelemetryRecord.sanitize_sql_array([
          "SELECT id FROM pg_temp.#{scratch} WHERE id > ? ORDER BY id LIMIT ?", after, limit
        ])).map(&:to_i)
        next 0 if ids.empty?

        after = ids.last.to_i
        deleted += connection.exec_delete(TelemetryRecord.sanitize_sql_array([ "DELETE FROM #{table} WHERE id IN (?)", ids ]))
        ids.size
      end
      deleted
    end
    private_class_method :delete_listed
  end
end
