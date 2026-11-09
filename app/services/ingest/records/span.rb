# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # A `span` record → a `spans` row: one step of a kept trace's waterfall.
    module Span
      extend T::Sig

      sig { params(record: Record, context: Context).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.build(record, context)
        trace = Coerce.trace_id(record["trace"])
        span = Coerce.span_id(record["span"])
        name = Coerce.str(record["name"], max: 200)
        duration = Coerce.ms(record["dur"])
        return nil unless trace && span && name && duration

        kind = record["kind"]
        {
          **context.stamp(record), trace_id: trace, span_id: span,
          parent_id: Coerce.span_id(record["parent"]), kind: Coerce.one_of(kind, Telemetry::Span::KINDS, "custom"),
          name: name, resource: Coerce.str(record["res"], max: 4_000), duration_ms: duration,
          status: Coerce.status(record["status"]), attrs: Coerce.attrs(record["attrs"])
        }
      end
    end
  end
end
