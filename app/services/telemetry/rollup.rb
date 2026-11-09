# typed: strict
# frozen_string_literal: true

module Telemetry
  # Folds metric points into a coarser tier: 10 s → 5 min → 1 h.
  # The summary columns fold with plain aggregates; the
  # sketch folds by summing counts per bucket — which is the reason a
  # distribution is stored as a sketch at all: the hourly p95 is computed
  # from the merged distribution, not averaged from 360 small p95s.
  #
  # Checkpointed (house invariant 1): a pass rolls only windows that have
  # fully closed, writes them idempotently, and advances its cursor in the
  # same transaction as the rows. A failed pass moves nothing.
  module Rollup
    extend T::Sig

    class Tier < T::Struct
      const :name, String
      const :source, String
      const :target, String
      const :width, ActiveSupport::Duration
      # How far behind the clock a window must be before it is rolled: late
      # batches for it have stopped arriving.
      const :lag, ActiveSupport::Duration
    end

    TIERS = T.let([
      Tier.new(name: "5m", source: "metric_points", target: "metric_points_5m", width: 5.minutes, lag: 1.minute),
      Tier.new(name: "1h", source: "metric_points_5m", target: "metric_points_1h", width: 1.hour, lag: 10.minutes)
    ].freeze, T::Array[Tier])

    # The most one pass rolls; a long-stopped worker catches up over a few
    # runs instead of one enormous statement.
    MAX_SPAN = T.let(12.hours, ActiveSupport::Duration)

    # Rows written, per tier name.
    sig { params(now: Time).returns(T::Hash[String, Integer]) }
    def self.run!(now: Time.now.utc)
      TIERS.to_h { |tier| [ tier.name, roll(tier, now: now) ] }
    end

    sig { params(tier: Tier, now: Time).returns(Integer) }
    def self.roll(tier, now:)
      cursor_name = "rollup:#{tier.name}"
      from = Cursor.position(cursor_name)&.utc || earliest(tier)
      return 0 if from.nil?

      from = floor(from, tier.width)
      to = [ floor(now - tier.lag, tier.width), from + MAX_SPAN ].min
      return 0 if to <= from

      written = T.let(0, Integer)
      TelemetryRecord.transaction do
        Partitions.ensure_for!([ tier.target ], from)
        Partitions.ensure_for!([ tier.target ], to - 1)
        written = connection.exec_update(TelemetryRecord.sanitize_sql_array([ fold_sql(tier), { from: from, to: to } ]))
        touch_series(tier, from, to)
        Cursor.advance!(cursor_name, to)
      end
      written
    end
    private_class_method :roll

    sig { params(tier: Tier).returns(String) }
    def self.fold_sql(tier)
      width = "#{tier.width.to_i} seconds"
      <<~SQL.squish
        WITH summary AS (
          SELECT series_id, date_bin('#{width}', ts, TIMESTAMPTZ 'epoch') AS bucket,
                 sum(n) AS n, sum(sum) AS sum, min(min) AS min, max(max) AS max,
                 (array_agg(last ORDER BY ts DESC) FILTER (WHERE last IS NOT NULL))[1] AS last
          FROM #{tier.source}
          WHERE ts >= :from AND ts < :to
          GROUP BY 1, 2
        ), buckets AS (
          SELECT series_id, date_bin('#{width}', ts, TIMESTAMPTZ 'epoch') AS bucket,
                 sketch[2 * g - 1] AS idx, sum(sketch[2 * g])::integer AS cnt
          FROM #{tier.source}
          CROSS JOIN LATERAL generate_series(1, cardinality(sketch) / 2) AS g
          WHERE ts >= :from AND ts < :to AND sketch IS NOT NULL
          GROUP BY 1, 2, 3
        ), merged AS (
          SELECT series_id, bucket, array_agg(v ORDER BY idx, k) AS sketch
          FROM buckets CROSS JOIN LATERAL (VALUES (1, idx), (2, cnt)) AS pair(k, v)
          GROUP BY 1, 2
        )
        INSERT INTO #{tier.target} (series_id, ts, n, sum, min, max, last, sketch)
        SELECT s.series_id, s.bucket, s.n, s.sum, s.min, s.max, s.last, m.sketch
        FROM summary s LEFT JOIN merged m USING (series_id, bucket)
        ON CONFLICT (series_id, ts) DO UPDATE
          SET n = EXCLUDED.n, sum = EXCLUDED.sum, min = EXCLUDED.min, max = EXCLUDED.max,
              last = EXCLUDED.last, sketch = EXCLUDED.sketch
      SQL
    end
    private_class_method :fold_sql

    # Only the first tier stamps series: it sees every point the others do.
    sig { params(tier: Tier, from: Time, to: Time).void }
    def self.touch_series(tier, from, to)
      return unless tier.source == "metric_points"

      connection.exec_update(TelemetryRecord.sanitize_sql_array([ <<~SQL.squish, { from: from, to: to } ]))
        UPDATE metric_series SET last_seen_at = seen.at
        FROM (SELECT series_id, max(ts) AS at FROM metric_points WHERE ts >= :from AND ts < :to GROUP BY 1) AS seen
        WHERE metric_series.id = seen.series_id AND metric_series.last_seen_at < seen.at
      SQL
    end
    private_class_method :touch_series

    sig { params(tier: Tier).returns(T.nilable(Time)) }
    def self.earliest(tier)
      value = connection.select_value("SELECT min(ts) FROM #{tier.source}")
      value.is_a?(Time) ? value.utc : nil
    end
    private_class_method :earliest

    sig { params(time: Time, width: ActiveSupport::Duration).returns(Time) }
    def self.floor(time, width) = Time.at(time.to_i - (time.to_i % width.to_i)).utc
    private_class_method :floor

    sig { returns(ActiveRecord::ConnectionAdapters::AbstractAdapter) }
    def self.connection = TelemetryRecord.connection
    private_class_method :connection
  end
end
