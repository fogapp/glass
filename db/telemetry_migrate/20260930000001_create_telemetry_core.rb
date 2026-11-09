# frozen_string_literal: true

# The telemetry database's first tables: the wide event,
# metrics and their series dictionary, markers, and process heartbeats.
#
# Every signal table is PARTITION BY RANGE (ts) with no partitions of its
# own — Telemetry::Partitions creates a day at a time, ahead of need, and
# retention is dropping one. Indexes declared on the parent are created on
# every partition automatically.
#
# Raw SQL throughout: partitioned tables are not something the schema DSL
# (or schema.rb, hence `schema_dump: false`) can express.
class CreateTelemetryCore < ActiveRecord::Migration[8.1]
  def up
    suppress_messages { execute(<<~SQL) }
      -- One row per request or job: the wide event.
      CREATE TABLE transactions (
        ts              timestamptz NOT NULL,
        app_id          integer     NOT NULL,
        kind            text        NOT NULL,           -- request | job
        name            text        NOT NULL,           -- "WantsController#index", "SearchPlanJob"
        process         text        NOT NULL DEFAULT 'web',
        host            text,
        release         text,
        trace_id        uuid        NOT NULL,
        span_id         bigint      NOT NULL,
        parent_span_id  bigint,                         -- set when continuing a remote trace
        duration_ms     real        NOT NULL,
        status          text        NOT NULL DEFAULT 'ok',  -- ok | error
        error_class     text,
        -- request
        method          text,
        route           text,                           -- "/api/v1/wants/:id"
        path            text,
        http_status     smallint,
        format          text,
        -- job
        queue           text,
        queue_ms        real,                           -- enqueue → perform latency
        attempt         smallint,
        -- where the time went, computed in the client
        db_ms           real        NOT NULL DEFAULT 0,
        db_count        integer     NOT NULL DEFAULT 0,
        view_ms         real        NOT NULL DEFAULT 0,
        ext_ms          real        NOT NULL DEFAULT 0,
        ext_count       integer     NOT NULL DEFAULT 0,
        cache_hits      integer     NOT NULL DEFAULT 0,
        cache_misses    integer     NOT NULL DEFAULT 0,
        gc_ms           real        NOT NULL DEFAULT 0,
        allocations     bigint,
        n_plus_one      boolean     NOT NULL DEFAULT false,
        -- who
        user_ref        text,                           -- per the app's identity mode
        visit_id        text,
        origin          text,                           -- lan | vpn | tunnel | public
        -- kept: the span tree for this trace was sent (tail sampling).
        -- weight: how many real transactions this row stands for; 1 unless
        -- the app was over its row budget.
        kept            boolean     NOT NULL DEFAULT false,
        weight          real        NOT NULL DEFAULT 1,
        attrs           jsonb       NOT NULL DEFAULT '{}'
      ) PARTITION BY RANGE (ts);

      CREATE INDEX transactions_ts_brin      ON transactions USING brin (ts);
      CREATE INDEX transactions_app_ts       ON transactions (app_id, ts);
      CREATE INDEX transactions_app_name_ts  ON transactions (app_id, name, ts);
      CREATE INDEX transactions_trace        ON transactions (trace_id);
      CREATE INDEX transactions_visit        ON transactions (visit_id, ts) WHERE visit_id IS NOT NULL;
      CREATE INDEX transactions_attrs        ON transactions USING gin (attrs jsonb_path_ops);

      -- Child spans of kept traces only.
      CREATE TABLE spans (
        ts          timestamptz NOT NULL,
        app_id      integer     NOT NULL,
        trace_id    uuid        NOT NULL,
        span_id     bigint      NOT NULL,
        parent_id   bigint,
        kind        text        NOT NULL,               -- sql | view | cache | http | enqueue | custom
        name        text        NOT NULL,
        resource    text,                               -- normalized SQL, template path, host + path
        duration_ms real        NOT NULL,
        status      text        NOT NULL DEFAULT 'ok',
        attrs       jsonb       NOT NULL DEFAULT '{}'
      ) PARTITION BY RANGE (ts);

      CREATE INDEX spans_ts_brin ON spans USING brin (ts);
      CREATE INDEX spans_trace   ON spans (trace_id);
      CREATE INDEX spans_app_kind_ts ON spans (app_id, kind, ts);

      -- The series dictionary: a point names its series by a 4-byte id
      -- instead of repeating the metric name and tags on every row.
      CREATE TABLE metric_series (
        id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        app_id        integer     NOT NULL,
        name          text        NOT NULL,
        kind          text        NOT NULL,             -- counter | gauge | dist | set
        unit          text,
        tags          jsonb       NOT NULL DEFAULT '{}',
        tags_hash     bigint      NOT NULL,
        first_seen_at timestamptz NOT NULL DEFAULT now(),
        last_seen_at  timestamptz NOT NULL DEFAULT now(),
        UNIQUE (app_id, name, tags_hash)
      );
      CREATE INDEX metric_series_tags ON metric_series USING gin (tags jsonb_path_ops);

      -- One row per series per flush window. Every kind fills the same
      -- summary (n, sum, min, max, last); a distribution adds its sketch
      -- (DDSketch buckets as alternating index, count — Telemetry::Sketch),
      -- which is what keeps percentiles correct when points are merged
      -- across series and rolled up across time.
      CREATE TABLE metric_points (
        series_id integer          NOT NULL,
        ts        timestamptz      NOT NULL,
        n         bigint           NOT NULL DEFAULT 0,
        sum       double precision NOT NULL DEFAULT 0,
        min       double precision,
        max       double precision,
        last      double precision,
        sketch    integer[]
      ) PARTITION BY RANGE (ts);
      CREATE INDEX metric_points_series_ts ON metric_points (series_id, ts);

      CREATE TABLE metric_points_5m (LIKE metric_points INCLUDING DEFAULTS) PARTITION BY RANGE (ts);
      CREATE UNIQUE INDEX metric_points_5m_series_ts ON metric_points_5m (series_id, ts);

      CREATE TABLE metric_points_1h (LIKE metric_points INCLUDING DEFAULTS) PARTITION BY RANGE (ts);
      CREATE UNIQUE INDEX metric_points_1h_series_ts ON metric_points_1h (series_id, ts);

      -- Things that happened at a moment and belong on every chart: deploys,
      -- restarts, incidents, annotations, Glass.event.
      CREATE TABLE markers (
        id       bigint GENERATED ALWAYS AS IDENTITY,
        ts       timestamptz NOT NULL,
        app_id   integer,                               -- null: fleet-wide
        kind     text        NOT NULL,                  -- deploy | restart | incident | event | annotation
        title    text        NOT NULL,
        release  text,
        source   text        NOT NULL DEFAULT 'agent',  -- agent | fog | glass | user
        attrs    jsonb       NOT NULL DEFAULT '{}'
      ) PARTITION BY RANGE (ts);
      CREATE INDEX markers_app_ts ON markers (app_id, ts);
      CREATE INDEX markers_ts     ON markers (ts);

      -- Agent heartbeats: one row per reporting process, touched on every
      -- batch. Small and unpartitioned; the Fleet page and absence monitors
      -- read it.
      CREATE TABLE processes (
        id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        app_id        integer     NOT NULL,
        kind          text        NOT NULL,             -- web | worker | …
        host          text        NOT NULL,
        pid           integer     NOT NULL,
        release       text,
        runtime       jsonb       NOT NULL DEFAULT '{}', -- ruby, rails, agent versions
        started_at    timestamptz,
        first_seen_at timestamptz NOT NULL DEFAULT now(),
        last_seen_at  timestamptz NOT NULL DEFAULT now(),
        batches       bigint      NOT NULL DEFAULT 0,
        records       bigint      NOT NULL DEFAULT 0,
        dropped       jsonb       NOT NULL DEFAULT '{}', -- what the agent says it shed, by type
        UNIQUE (app_id, host, pid, kind)
      );
      CREATE INDEX processes_last_seen ON processes (last_seen_at);

      -- Checkpoints for worker passes over telemetry (rollups). Advanced only
      -- when the pass committed (the house invariant: a checkpoint never
      -- moves on failure).
      CREATE TABLE cursors (
        name       text PRIMARY KEY,
        position   timestamptz NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT now()
      );
    SQL
  end

  def down
    suppress_messages { execute(<<~SQL) }
      DROP TABLE IF EXISTS cursors, processes, markers, metric_points_1h, metric_points_5m,
        metric_points, metric_series, spans, transactions CASCADE;
    SQL
  end
end
