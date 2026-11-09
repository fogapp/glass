# typed: strict
# frozen_string_literal: true

module Ingest
  # A parsed batch → rows, in one transaction on the telemetry database.
  # Synchronous on purpose: a few multi-row inserts are
  # milliseconds, and an ingest path that needs the worker is an ingest path
  # that stops when the worker does.
  #
  # This is the one write path for a batch: the demo (lib/demo) writes its
  # history through it too, with `heartbeat: false` — history is not a
  # process reporting now — so a new signal table is written everywhere
  # once it is written here.
  module Writer
    extend T::Sig

    sig { params(app: App, batch: Batch, heartbeat: T::Boolean).void }
    def self.write!(app, batch, heartbeat: true)
      attempt(app, batch, heartbeat: heartbeat)
    rescue ActiveRecord::StatementInvalid => e
      # A row for a day with no partition — maintenance has not run since
      # the box woke up. Create the days around the batch's clock (which
      # bounds every record's time) and write once more.
      raise unless e.cause.is_a?(PG::CheckViolation)

      Telemetry::Partitions.ensure!(today: batch.clock.now.utc.to_date)
      attempt(app, batch, heartbeat: heartbeat)
    end

    sig { params(app: App, batch: Batch, heartbeat: T::Boolean).void }
    def self.attempt(app, batch, heartbeat:)
      # Dictionaries first, outside the write transaction: a series, a
      # function or a stack is an entry worth keeping even if this batch's
      # rows are not.
      series_ids = SeriesResolver.resolve(app, batch.metrics)
      profile_rows = batch.profiles.flat_map { |window| ProfileStore.rows(app, batch.header, window) }

      TelemetryRecord.transaction do
        Records::TYPES.each do |type, kind|
          table = kind.table
          insert(table, batch.rows(type)) if table
        end
        insert(Telemetry::MetricPoint, metric_rows(batch.metrics, series_ids))
        insert(Telemetry::ProfileSample, profile_rows)
        Visits.fold!(app, batch.pages)
        Heartbeat.beat!(app, batch.header, records: batch.accepted, now: batch.clock.now) if heartbeat
      end
    end
    private_class_method :attempt

    # Slices keep one statement's bind count well under Postgres's 65,535.
    sig { params(model: T.class_of(TelemetryRecord), rows: T::Array[T::Hash[Symbol, T.untyped]]).void }
    def self.insert(model, rows)
      rows.each_slice(1_000) do |slice|
        model.insert_all!(slice, returning: false, record_timestamps: false) # rubocop:disable Rails/SkipsModelValidations
      end
    end
    private_class_method :insert

    sig do
      params(points: T::Array[Records::Metric::Point], series_ids: T::Array[Integer])
        .returns(T::Array[T::Hash[Symbol, T.untyped]])
    end
    def self.metric_rows(points, series_ids)
      points.zip(series_ids).map do |point, series_id|
        { series_id: series_id, ts: point.ts, n: point.n, sum: point.sum, min: point.min, max: point.max,
          last: point.last, sketch: point.sketch }
      end
    end
    private_class_method :metric_rows
  end
end
