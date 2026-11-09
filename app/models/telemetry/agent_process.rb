# typed: strict
# frozen_string_literal: true

module Telemetry
  # One reporting process — a Puma worker, a Solid Queue worker — as its
  # agent describes itself in every batch header. `last_seen_at` is the
  # heartbeat the Fleet page and absence monitors read.
  class AgentProcess < TelemetryRecord
    extend T::Sig

    self.table_name = "processes"

    # A process that has flushed within this window is reporting; agents
    # flush every ten seconds, so three misses is silence, not jitter.
    LIVE_WITHIN = T.let(45.seconds, ActiveSupport::Duration)

    scope :live, -> { where(last_seen_at: LIVE_WITHIN.ago..) }

    sig { returns(T::Boolean) }
    def live? = last_seen_at > LIVE_WITHIN.ago

    # The fleet's processes at a glance — the status line's and whoami's —
    # read in one statement.
    class Summary < T::Struct
      const :live, Integer
      const :total, Integer
      const :last_seen_at, T.nilable(Time)
      # The apps with a live process.
      const :reporting, T::Array[Integer]
    end

    sig { params(app_ids: T::Array[Integer]).returns(Summary) }
    def self.summary(app_ids)
      live = sanitize_sql_array([ "last_seen_at >= ?", LIVE_WITHIN.ago ])
      live_count, total, last_seen_at, reporting = where(app_id: app_ids).pick(
        Arel.sql("count(*) FILTER (WHERE #{live})"), Arel.sql("count(*)"), Arel.sql("max(last_seen_at)"),
        Arel.sql("array_agg(DISTINCT app_id) FILTER (WHERE #{live})")
      )
      Summary.new(live: live_count.to_i, total: total.to_i, last_seen_at: last_seen_at, reporting: Array(reporting).map(&:to_i))
    end
  end
end
