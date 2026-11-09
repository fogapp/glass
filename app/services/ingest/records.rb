# typed: strict
# frozen_string_literal: true

module Ingest
  # One builder per record type (docs/ingest-protocol.md), each turning a
  # decoded record into what its table holds — or nil, and the record is
  # counted and skipped. TYPES is the whole list: Batch parses by it and
  # Writer inserts by it, so a new record type is a builder and an entry.
  module Records
    extend T::Sig

    Record = T.type_alias { T::Hash[String, T.untyped] }

    # A record type: how it is built, and the table its rows go into. No
    # table means the rows name dictionary entries the Writer resolves
    # first (metric points, profile windows), and it writes them itself.
    class Type < T::Struct
      const :build, T.proc.params(record: Record, context: Context).returns(T.untyped)
      const :table, T.nilable(T.class_of(TelemetryRecord))
    end

    # By wire type (the record's "t"). The order is the order of inserts.
    TYPES = T.let({
      "txn" => Type.new(build: ->(record, context) { Txn.build(record, context) }, table: Telemetry::Transaction),
      "span" => Type.new(build: ->(record, context) { Span.build(record, context) }, table: Telemetry::Span),
      "marker" => Type.new(build: ->(record, context) { Marker.build(record, context) }, table: Telemetry::Marker),
      "metric" => Type.new(build: ->(record, context) { Metric.build(record, context) }, table: nil),
      "log" => Type.new(build: ->(record, context) { Log.build(record, context) }, table: Telemetry::LogLine),
      "profile" => Type.new(build: ->(record, context) { Profile.build(record, context) }, table: nil),
      "page" => Type.new(build: ->(record, context) { Page.build(record, context) }, table: Telemetry::PageEvent),
      "llm" => Type.new(build: ->(record, context) { Llm.build(record, context) }, table: Telemetry::ModelCall)
    }.freeze, T::Hash[String, Type])
  end
end
