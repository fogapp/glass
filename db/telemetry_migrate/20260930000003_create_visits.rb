# frozen_string_literal: true

# Visitor analytics: what people did in the browser, and the
# visits those things add up to.
class CreateVisits < ActiveRecord::Migration[8.1]
  def up
    suppress_messages { execute(<<~SQL) }
      -- One row per thing a visitor did: a pageview, a click, a form, the
      -- vitals of a page, a custom event, a browser error.
      CREATE TABLE page_events (
        ts          timestamptz NOT NULL,
        app_id      integer     NOT NULL,
        kind        text        NOT NULL,        -- pageview | click | submit | vital | custom | error
        visit_id    text        NOT NULL,
        visitor_id  text,
        user_ref    text,
        path        text,
        route       text,
        title       text,
        referrer    text,                        -- host of the visit's first referrer
        name        text,                        -- accessible name of the thing clicked, the event, the error
        selector    text,                        -- the element, as a stable selector
        href        text,
        browser     text,
        os          text,
        device      text,                        -- phone | tablet | desktop
        screen      text,
        lang        text,
        origin      text,                        -- lan | vpn | tunnel | public
        rage        boolean     NOT NULL DEFAULT false,
        lcp         real,
        inp         real,
        cls         real,
        ttfb        real,
        fcp         real,
        props       jsonb       NOT NULL DEFAULT '{}'
      ) PARTITION BY RANGE (ts);
      CREATE INDEX page_events_ts_brin ON page_events USING brin (ts);
      CREATE INDEX page_events_app_ts  ON page_events (app_id, ts);
      CREATE INDEX page_events_visit   ON page_events (visit_id, ts);

      -- One row per visit, assembled on ingest from its events: entry and
      -- exit, how long, how much. Partitioned by when it began.
      CREATE TABLE visits (
        ts            timestamptz NOT NULL,      -- began
        last_seen_at  timestamptz NOT NULL,
        app_id        integer     NOT NULL,
        visit_id      text        NOT NULL,
        visitor_id    text,
        user_ref      text,
        entry_path    text,
        entry_route   text,
        exit_path     text,
        referrer      text,
        browser       text,
        os            text,
        device        text,
        origin        text,
        pageviews     integer     NOT NULL DEFAULT 0,
        interactions  integer     NOT NULL DEFAULT 0,
        error_count   integer     NOT NULL DEFAULT 0,
        UNIQUE (app_id, visit_id, ts)
      ) PARTITION BY RANGE (ts);
      CREATE INDEX visits_app_ts ON visits (app_id, ts);
      CREATE INDEX visits_visitor ON visits (visitor_id, ts) WHERE visitor_id IS NOT NULL;
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS visits, page_events CASCADE"
  end
end
