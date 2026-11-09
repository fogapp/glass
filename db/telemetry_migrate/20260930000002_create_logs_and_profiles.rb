# frozen_string_literal: true

# Logs, and profiles as a stack store.
#
# A profile is not stored as a profile. A window arrives folded to
# (transaction, state, stack) → weight; the functions and stacks it names
# are re-keyed by content into two dictionaries, so a stack sampled ten
# thousand times across a week of windows and four processes is one row in
# profile_stacks and its weight is a row a minute in profile_samples. A
# flamegraph for any filter is then one GROUP BY and a dictionary lookup —
# which is also what makes "the flamegraph of one endpoint on one release"
# a WHERE clause rather than a feature.
class CreateLogsAndProfiles < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pg_trgm"

    suppress_messages { execute(<<~SQL) }
      CREATE TABLE logs (
        ts        timestamptz NOT NULL,
        app_id    integer     NOT NULL,
        process   text        NOT NULL DEFAULT 'web',
        host      text,
        release   text,
        level     text        NOT NULL DEFAULT 'info',   -- debug | info | warn | error | fatal
        message   text        NOT NULL,
        source    text        NOT NULL DEFAULT 'rails',  -- rails | event | <app-chosen>
        trace_id  uuid,
        span_id   bigint,
        attrs     jsonb       NOT NULL DEFAULT '{}'
      ) PARTITION BY RANGE (ts);

      CREATE INDEX logs_ts_brin  ON logs USING brin (ts);
      CREATE INDEX logs_app_ts   ON logs (app_id, ts);
      CREATE INDEX logs_trace    ON logs (trace_id) WHERE trace_id IS NOT NULL;
      -- Substring search ("timeout") without a full-text dictionary: log
      -- lines are not prose.
      CREATE INDEX logs_message_trgm ON logs USING gin (message gin_trgm_ops);

      -- A function, once per app however often it is sampled. Identity is
      -- name + file (profile_functions.digest); the line is where it was
      -- last seen to start, which moves with every edit and so is not
      -- identity.
      CREATE TABLE profile_functions (
        id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        app_id    integer NOT NULL,
        digest    bigint  NOT NULL,
        name      text    NOT NULL,
        file      text    NOT NULL DEFAULT '',
        line      integer NOT NULL DEFAULT 0,
        category  text    NOT NULL DEFAULT 'app',        -- app | gem | ruby | native
        UNIQUE (app_id, digest)
      );

      -- A call stack, once per app: function ids, root first.
      CREATE TABLE profile_stacks (
        id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        app_id  integer   NOT NULL,
        digest  bigint    NOT NULL,
        frames  integer[] NOT NULL,
        UNIQUE (app_id, digest)
      );

      -- The samples: how much of a window each stack accounted for, by
      -- what the thread was doing and which transaction it was serving.
      CREATE TABLE profile_samples (
        ts           timestamptz NOT NULL,                -- window start
        app_id       integer     NOT NULL,
        process      text        NOT NULL DEFAULT 'web',
        host         text,
        release      text,
        txn          text,                                -- the transaction; null: outside any request or job
        state        text        NOT NULL DEFAULT 'running',  -- running | stalled | idle | gc
        stack_id     bigint      NOT NULL,
        samples      integer     NOT NULL,
        -- samples × 1000 / hz, stored so windows taken at different rates
        -- add up as time.
        ms           real        NOT NULL,
        request_id   text                                 -- a "profile now" request
      ) PARTITION BY RANGE (ts);

      CREATE INDEX profile_samples_ts_brin ON profile_samples USING brin (ts);
      CREATE INDEX profile_samples_app_ts  ON profile_samples (app_id, ts);
      CREATE INDEX profile_samples_request ON profile_samples (request_id) WHERE request_id IS NOT NULL;
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS profile_samples, profile_stacks, profile_functions, logs CASCADE"
  end
end
