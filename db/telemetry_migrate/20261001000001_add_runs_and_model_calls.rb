# frozen_string_literal: true

# Agent harnesses.
#
# A run is a third kind of unit of work, so it is a row of `transactions`
# like a request or a job, and what is particular to it is two more facets
# on that row (Telemetry::Work): `ai` — who ran, in which conversation,
# what it spent — and `experience` — where the time between asking and
# being answered went. Adding columns to a partitioned parent is a catalog
# change; no partition is rewritten.
#
# A model call is one-to-many under a run, so it is a table of its own that
# names its trace and span, as spans and logs do. It is kept whole — never
# sampled — because spend is only exact if every call is counted.
class AddRunsAndModelCalls < ActiveRecord::Migration[8.1]
  def up
    suppress_messages { execute(<<~SQL) }
      ALTER TABLE transactions
        -- ai
        ADD COLUMN agent              text,
        ADD COLUMN session            text,              -- the conversation
        ADD COLUMN trigger            text,              -- message | cron | task | …
        ADD COLUMN channel            text,              -- telegram | console | voice | …
        ADD COLUMN stop               text,              -- why it ended: ok | rounds | tokens | cancelled | …
        ADD COLUMN model              text,              -- the model that gave the answer
        ADD COLUMN rounds             integer NOT NULL DEFAULT 0,
        ADD COLUMN model_calls        integer NOT NULL DEFAULT 0,
        ADD COLUMN tool_calls         integer NOT NULL DEFAULT 0,
        ADD COLUMN tool_errors        integer NOT NULL DEFAULT 0,
        ADD COLUMN tokens_in          integer NOT NULL DEFAULT 0,   -- uncached input
        ADD COLUMN tokens_out         integer NOT NULL DEFAULT 0,
        ADD COLUMN tokens_cache_read  integer NOT NULL DEFAULT 0,
        ADD COLUMN tokens_cache_write integer NOT NULL DEFAULT 0,
        ADD COLUMN cost_usd           double precision NOT NULL DEFAULT 0,
        -- experience: the phases (with queue_ms) that add up to duration_ms…
        ADD COLUMN prep_ms            real NOT NULL DEFAULT 0,      -- memory, context
        ADD COLUMN model_ms           real NOT NULL DEFAULT 0,
        ADD COLUMN tool_ms            real NOT NULL DEFAULT 0,
        ADD COLUMN wait_ms            real NOT NULL DEFAULT 0,      -- waiting on a person
        ADD COLUMN deliver_ms         real NOT NULL DEFAULT 0,
        -- …and what the person felt.
        ADD COLUMN lag_ms             real,                         -- wanted → begun, before ts
        ADD COLUMN ttft_ms            real,                         -- begun → first visible text
        ADD COLUMN stall_ms           real;                         -- the longest silence

      CREATE INDEX transactions_session ON transactions (app_id, session, ts) WHERE session IS NOT NULL;

      CREATE TABLE model_calls (
        ts                 timestamptz NOT NULL,
        app_id             integer     NOT NULL,
        process            text        NOT NULL DEFAULT 'web',
        host               text,
        release            text,
        trace_id           uuid,
        span_id            bigint,
        provider           text        NOT NULL,
        model              text        NOT NULL,                -- asked for
        served             text,                                -- answered
        tier               text,
        purpose            text        NOT NULL DEFAULT 'turn', -- turn | reviewer | title | compaction | …
        origin             text        NOT NULL DEFAULT 'production',  -- production | internal | eval
        agent              text,
        session            text,
        round              integer,
        status             text        NOT NULL DEFAULT 'ok',   -- ok | error
        error_class        text,
        stop               text,
        route              text,                                -- why this model
        retry_of           bigint,                              -- the span of the call this one retries
        fallback_from      text,                                -- the provider that failed first
        stream             boolean     NOT NULL DEFAULT false,
        duration_ms        real        NOT NULL,
        ttft_ms            real,
        first_text_ms      real,
        itl_p95_ms         real,
        -- the server's own account of its time, when it gives one
        queue_ms           real,
        load_ms            real,
        prompt_ms          real,
        decode_ms          real,
        concurrent         integer,
        tokens_in          integer     NOT NULL DEFAULT 0,      -- uncached input
        tokens_cache_read  integer     NOT NULL DEFAULT 0,
        tokens_cache_write integer     NOT NULL DEFAULT 0,
        tokens_out         integer     NOT NULL DEFAULT 0,
        tokens_reasoning   integer     NOT NULL DEFAULT 0,
        estimated          boolean     NOT NULL DEFAULT false,  -- counts are from text length
        cost_usd           double precision NOT NULL DEFAULT 0,
        cost_source        text,                                -- reported | estimated | shadow | free
        tool_calls         integer     NOT NULL DEFAULT 0,
        tool_calls_valid   integer,
        attrs              jsonb       NOT NULL DEFAULT '{}'
      ) PARTITION BY RANGE (ts);

      CREATE INDEX model_calls_ts_brin   ON model_calls USING brin (ts);
      CREATE INDEX model_calls_app_ts    ON model_calls (app_id, ts);
      CREATE INDEX model_calls_app_model ON model_calls (app_id, model, ts);
      CREATE INDEX model_calls_trace     ON model_calls (trace_id) WHERE trace_id IS NOT NULL;
    SQL
  end

  def down
    suppress_messages { execute(<<~SQL) }
      DROP TABLE IF EXISTS model_calls CASCADE;
      DROP INDEX IF EXISTS transactions_session;
      ALTER TABLE transactions
        DROP COLUMN agent, DROP COLUMN session, DROP COLUMN trigger, DROP COLUMN channel, DROP COLUMN stop, DROP COLUMN model,
        DROP COLUMN rounds, DROP COLUMN model_calls, DROP COLUMN tool_calls, DROP COLUMN tool_errors,
        DROP COLUMN tokens_in, DROP COLUMN tokens_out, DROP COLUMN tokens_cache_read, DROP COLUMN tokens_cache_write,
        DROP COLUMN cost_usd, DROP COLUMN prep_ms, DROP COLUMN model_ms, DROP COLUMN tool_ms, DROP COLUMN wait_ms,
        DROP COLUMN deliver_ms, DROP COLUMN lag_ms, DROP COLUMN ttft_ms, DROP COLUMN stall_ms;
    SQL
  end
end
