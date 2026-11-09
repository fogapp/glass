# typed: strict
# frozen_string_literal: true

# What an app row in the console says about right now, read for a list of
# apps in two queries: is it reporting, from how many processes, on which
# release.
module AppHealth
  extend T::Sig

  class Summary < T::Struct
    const :live_processes, Integer
    const :processes, Integer
    const :release, T.nilable(String)
    const :last_seen_at, T.nilable(Time)
    # The kinds of unit of work it has reported lately (Telemetry::Work):
    # what the console builds an app's page from.
    const :kinds, T::Array[String], default: []
  end

  KINDS_WITHIN = T.let(7.days, ActiveSupport::Duration)
  KINDS_FRESH_FOR = T.let(5.minutes, ActiveSupport::Duration)

  sig { params(apps: T::Array[App]).returns(T::Hash[Integer, Summary]) }
  def self.for(apps)
    ids = apps.map(&:telemetry_id)
    return {} if ids.empty?

    live = Telemetry::AgentProcess.sanitize_sql_array([ "last_seen_at > ?", Telemetry::AgentProcess::LIVE_WITHIN.ago ])
    rows = Telemetry::AgentProcess.where(app_id: ids).group(:app_id).pluck(
      :app_id, Arel.sql("count(*) FILTER (WHERE #{live})"), Arel.sql("count(*)"),
      Arel.sql("(array_agg(release ORDER BY last_seen_at DESC))[1]"), Arel.sql("max(last_seen_at)")
    )
    kinds = kinds_for(ids)
    rows.to_h do |id, live_count, total, release, last_seen_at|
      [ id, Summary.new(
        live_processes: live_count.to_i, processes: total.to_i,
        release: release, last_seen_at: last_seen_at, kinds: kinds.fetch(id, [])
      ) ]
    end
  end

  # Which kinds each app has reported in the last week. A scan of a week of
  # rows per app list would be paid on every page, and the answer changes
  # the day an app starts reporting a new kind, not by the minute. Kept per
  # app, so the list, an app's page and the MCP tools share the answers;
  # the apps none is kept for are read in one statement.
  sig { params(ids: T::Array[Integer]).returns(T::Hash[Integer, T::Array[String]]) }
  def self.kinds_for(ids)
    keys = ids.uniq.to_h { |id| [ id, [ "app_health/kinds", id ] ] }
    # T.unsafe: Sorbet splats only arrays of a size it knows.
    cached = T.unsafe(Rails.cache).read_multi(*keys.values)
    missing = keys.reject { |_, key| cached.key?(key) }.keys
    if missing.any?
      found = Telemetry::Transaction.where(app_id: missing, ts: KINDS_WITHIN.ago..).distinct.pluck(:app_id, :kind)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }
      fresh = missing.to_h { |id| [ keys.fetch(id), found.fetch(id, []) ] }
      Rails.cache.write_multi(fresh, expires_in: KINDS_FRESH_FOR)
      cached.merge!(fresh)
    end
    keys.to_h { |id, key| [ id, cached.fetch(key) ] }.reject { |_, kinds| kinds.empty? }
  end
end
