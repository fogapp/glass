# typed: strict
# frozen_string_literal: true

module Ingest
  # Visits, assembled as their events arrive: one row per (app, visit),
  # begun at its first event, updated with every batch that mentions it.
  # Done here rather than by a worker because a live "who is on now" is the
  # whole point of the row.
  #
  # A batch costs one read of the rows its visits already have and one
  # write of the folded result, however many visits it mentions.
  module Visits
    extend T::Sig

    # A visit's row lives in the partition of the day it began; an event
    # for a visit begun before this window starts one that day's row.
    LOOKBACK = T.let(2.days, ActiveSupport::Duration)

    Row = T.type_alias { T::Hash[Symbol, T.untyped] }

    sig { params(app: App, rows: T::Array[Row]).void }
    def self.fold!(app, rows)
      return if rows.empty?

      visits = rows.group_by { |row| row[:visit_id] }.transform_values { |events| events.sort_by { |row| row[:ts] } }
      existing = existing_rows(app, visits)
      folded = visits.sort.map { |visit_id, events| fold(app, visit_id, events, existing[visit_id]) }

      folded.each_slice(1_000) do |slice|
        Telemetry::Visit.upsert_all(slice, unique_by: %i[app_id visit_id ts]) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    # Each visit's row: the earliest one begun no more than LOOKBACK before
    # the visit's first event in this batch. One query reads every visit's
    # candidates from the widest window, and each picks its own from them.
    sig { params(app: App, visits: T::Hash[String, T::Array[Row]]).returns(T::Hash[String, Telemetry::Visit]) }
    def self.existing_rows(app, visits)
      since = visits.transform_values { |events| T.must(events.first)[:ts] - LOOKBACK }
      candidates = Telemetry::Visit.where(app_id: app.telemetry_id, visit_id: visits.keys, ts: since.values.min..).order(:ts)
      candidates.each_with_object({}) do |visit, out|
        out[visit.visit_id] ||= visit if visit.ts >= since.fetch(visit.visit_id)
      end
    end
    private_class_method :existing_rows

    sig { params(app: App, visit_id: String, events: T::Array[Row], existing: T.nilable(Telemetry::Visit)).returns(Row) }
    def self.fold(app, visit_id, events, existing)
      first = T.must(events.first)
      last = T.must(events.last)
      pageviews = events.select { |row| row[:kind] == "pageview" }
      began = existing&.ts || first[:ts]
      identity = events.reverse.find { |row| row[:user_ref] } || first

      {
        ts: began, last_seen_at: [ existing&.last_seen_at, last[:ts] ].compact.max, app_id: app.telemetry_id, visit_id: visit_id,
        visitor_id: identity[:visitor_id] || existing&.visitor_id, user_ref: identity[:user_ref] || existing&.user_ref,
        entry_path: existing&.entry_path || pageviews.first&.fetch(:path), entry_route: existing&.entry_route || pageviews.first&.fetch(:route),
        exit_path: pageviews.last&.fetch(:path) || existing&.exit_path,
        referrer: existing&.referrer || events.filter_map { |row| row[:referrer] }.first,
        browser: existing&.browser || first[:browser], os: existing&.os || first[:os], device: existing&.device || first[:device],
        origin: existing&.origin || first[:origin],
        pageviews: (existing&.pageviews || 0) + pageviews.size,
        interactions: (existing&.interactions || 0) + events.count { |row| Telemetry::PageEvent::INTERACTIONS.include?(row[:kind]) },
        error_count: (existing&.error_count || 0) + events.count { |row| row[:kind] == "error" }
      }
    end
    private_class_method :fold
  end
end
