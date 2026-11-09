# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # A `marker` record → a `markers` row: what Glass.event sends.
    module Marker
      extend T::Sig

      # What an agent may claim. Incidents are Glass's own to write.
      KINDS = T.let(
        (Telemetry::Marker::Kind.values - [ Telemetry::Marker::Kind::Incident ]).map(&:serialize).freeze,
        T::Array[String]
      )

      sig { params(record: Record, context: Context).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.build(record, context)
        title = Coerce.str(record["title"], max: 200)
        return nil if title.nil?

        kind = record["kind"]
        {
          **context.stamp(record), kind: Coerce.one_of(kind, KINDS, Telemetry::Marker::Kind::Event.serialize),
          title: title, release: context.header.release, source: "agent", attrs: Coerce.attrs(record["attrs"])
        }
      end
    end
  end
end
