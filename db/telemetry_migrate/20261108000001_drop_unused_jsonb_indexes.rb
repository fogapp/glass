# frozen_string_literal: true

# The jsonb_path_ops GIN indexes on transactions.attrs and
# metric_series.tags serve only containment (@>, @?), and nothing asks
# that: an attribute or tag filter compiles to `attrs->>key` / `tags->>key`
# with = or LIKE (Query::Where, Query::Metrics), which they cannot answer.
# Every insert paid a GIN update for an index no plan used. Dropping the
# index on the partitioned parent drops each day's copy with it.
class DropUnusedJsonbIndexes < ActiveRecord::Migration[8.1]
  def up
    suppress_messages { execute("DROP INDEX IF EXISTS transactions_attrs; DROP INDEX IF EXISTS metric_series_tags;") }
  end

  def down
    suppress_messages { execute(<<~SQL) }
      CREATE INDEX IF NOT EXISTS transactions_attrs ON transactions USING gin (attrs jsonb_path_ops);
      CREATE INDEX IF NOT EXISTS metric_series_tags ON metric_series USING gin (tags jsonb_path_ops);
    SQL
  end
end
