# frozen_string_literal: true

# What a person saw of a run. The server can say
# when a token was sent; only the browser can say when it was painted. A
# page event may name the trace it belongs to, so the moment the first
# answer text appeared on screen sits in the same trace as the run that
# produced it.
class AddTraceToPageEvents < ActiveRecord::Migration[8.1]
  def up
    suppress_messages { execute(<<~SQL) }
      ALTER TABLE page_events ADD COLUMN trace_id uuid;
      CREATE INDEX page_events_trace ON page_events (trace_id) WHERE trace_id IS NOT NULL;
    SQL
  end

  def down
    suppress_messages { execute("DROP INDEX IF EXISTS page_events_trace; ALTER TABLE page_events DROP COLUMN trace_id;") }
  end
end
