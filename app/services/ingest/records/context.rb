# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # What every builder is handed beside its record: whose batch it is,
    # the process that sent it, and the clock its timestamps are judged by.
    class Context < T::Struct
      extend T::Sig

      const :app_id, Integer
      const :header, Batch::Header
      const :clock, Clock

      # When and whose: what every row starts with.
      sig { params(record: Record).returns(T::Hash[Symbol, T.untyped]) }
      def stamp(record) = { ts: time(record), app_id: app_id }

      # When and whose, and which process, host and release said it.
      sig { params(record: Record).returns(T::Hash[Symbol, T.untyped]) }
      def provenance(record) = header.provenance(ts: time(record), app_id: app_id)

      # The record's own time, if the clock believes it.
      sig { params(record: Record).returns(Time) }
      def time(record) = clock.time(record["ts"])
    end
  end
end
