# typed: strict
# frozen_string_literal: true

module Traces
  # One trace, whole: every transaction that carried the id (a request and
  # the jobs it enqueued, across apps) and the spans kept for them. The
  # console's waterfall and the MCP `get_trace` tool both read it here.
  module Lookup
    extend T::Sig

    HEX32 = /\A[0-9a-f]{32}\z/
    # A trace is looked up by id alone, so the search has to be bounded by
    # time some other way: the longest anything is kept.
    LOOKBACK = T.let(45.days, ActiveSupport::Duration)
    MAX_TRANSACTIONS = 200
    MAX_SPANS = 5_000
    MAX_MODEL_CALLS = 500
    # How far past its transactions a trace's spans and model calls are
    # looked for: clocks differ between hosts (mcp get_trace bounds a
    # trace's logs by the same minute).
    MARGIN = T.let(1.minute, ActiveSupport::Duration)

    class Found < T::Struct
      const :id, String
      const :transactions, T::Array[Telemetry::Transaction]
      const :spans, T::Array[Telemetry::Span]
      # The model calls made under the trace, each naming the span it was.
      const :model_calls, T::Array[Telemetry::ModelCall]
      # There were more spans than were asked for.
      const :truncated, T::Boolean
    end

    # The id as stored — lowercase hex, no dashes — or nil when what was
    # given is not a trace id.
    sig { params(raw: T.untyped).returns(T.nilable(String)) }
    def self.normalize(raw)
      id = raw.to_s.strip.downcase.delete("-")
      HEX32.match?(id) ? id : nil
    end

    # nil when the asker's apps hold nothing under that id.
    sig { params(id: String, context: Query::Context, max_spans: Integer).returns(T.nilable(Found)) }
    def self.call(id:, context:, max_spans: MAX_SPANS)
      # Under the statement timeout every console query runs under.
      Query::Runner.timed(slow: "the trace is too large to read whole") do
        transactions = Telemetry::Transaction.where(trace_id: id, app_id: context.app_ids, ts: LOOKBACK.ago..)
          .order(:ts).limit(MAX_TRANSACTIONS).to_a
        next nil if transactions.empty?

        during = span_of(transactions)
        spans = Telemetry::Span.where(trace_id: id, app_id: context.app_ids, ts: during).order(:ts).limit(max_spans + 1).to_a
        model_calls = Telemetry::ModelCall.where(trace_id: id, app_id: context.app_ids, ts: during).order(:ts).limit(MAX_MODEL_CALLS).to_a
        Found.new(id: id, transactions: transactions, spans: spans.first(max_spans), model_calls: model_calls,
          truncated: spans.size > max_spans)
      end
    end

    # When the trace's spans and model calls can be: around its
    # transactions, give or take MARGIN, so only those days' partitions are
    # read. Open-ended when the transactions were cut at MAX_TRANSACTIONS —
    # the ones not read could end later.
    sig { params(transactions: T::Array[Telemetry::Transaction]).returns(T::Range[ActiveSupport::TimeWithZone]) }
    def self.span_of(transactions)
      from = T.must(transactions.map(&:ts).min) - MARGIN
      return (from..) if transactions.size >= MAX_TRANSACTIONS

      to = transactions.map { |txn| txn.ts + txn.duration_ms.to_f / 1000.0 }.max
      from..(to + MARGIN)
    end
    private_class_method :span_of
  end
end
