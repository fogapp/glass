# typed: strict
# frozen_string_literal: true

# The one read of markers — deploys, restarts, incidents, events — for the
# console's chart lines, the list_markers tool and triage's evidence alike.
# Not a Query::Source: a marker with no app is the fleet's own (Glass
# itself), and a source's Where keeps only the asker's apps, so it would
# drop those. The access boundary is the same Query::Context all the same.
module Markers
  extend T::Sig

  # Newest first. Without `app`, the household's apps and the fleet-wide
  # markers; with one, that app's only — and an app the household does not
  # have matches nothing (Query::Context#app_id), for a caller that wants
  # to say so to check first. `kinds` nil is every kind.
  sig do
    params(context: Query::Context, from: Time, to: Time, limit: Integer, app: T.nilable(String),
      kinds: T.nilable(T::Array[String])).returns(T::Array[Telemetry::Marker])
  end
  def self.within(context, from:, to:, limit:, app: nil, kinds: nil)
    apps = app ? [ context.app_id(app) ].compact : context.app_ids + [ nil ]
    return [] if apps.empty?

    scope = Telemetry::Marker.where(ts: from...to, app_id: apps)
    scope = scope.where(kind: kinds) if kinds
    scope.order(ts: :desc).limit(limit).to_a
  end
end
