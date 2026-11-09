# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # A `log` record → a `logs` row.
    module Log
      extend T::Sig

      MAX_MESSAGE = 8_000

      sig { params(record: Record, context: Context).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.build(record, context)
        message = Coerce.str(record["msg"], max: MAX_MESSAGE)
        return nil if message.nil?

        level = record["lvl"]
        {
          **context.provenance(record),
          level: Coerce.one_of(level, Telemetry::LogLine::LEVELS, "info"),
          message: message, source: Coerce.str(record["src"], max: 60) || "rails",
          trace_id: Coerce.trace_id(record["trace"]), span_id: Coerce.span_id(record["span"]),
          attrs: Coerce.attrs(record["attrs"])
        }
      end
    end
  end
end
