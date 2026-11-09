# typed: strict
# frozen_string_literal: true

module Telemetry
  # One unit of work — a request, a job, an agent's run: the wide event,
  # a spine with facets (Telemetry::Work). Written by
  # ingest, read through the query engine — nothing else touches the table.
  class Transaction < TelemetryRecord
    self.table_name = "transactions"
    # Partitioned, append-only, no primary key: a row is found by
    # (trace_id, span_id) or by what it measured.
    self.primary_key = nil
  end
end
