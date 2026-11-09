# typed: strict
# frozen_string_literal: true

module MarkerSerializer
  extend T::Sig

  sig { params(marker: Telemetry::Marker, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
  def self.marker_json(marker, context)
    {
      ts: marker.ts.to_f, app: context.slug(marker.app_id), kind: marker.kind, title: marker.title,
      release: marker.release, source: marker.source, attrs: marker.attrs
    }
  end
end
