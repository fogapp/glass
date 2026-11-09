# typed: strict
# frozen_string_literal: true

module Ingest
  # One parsed glass-ingest/1 body (docs/ingest-protocol.md): the header,
  # and every record turned into a row for its table. A malformed or unknown
  # record is counted and skipped — one bad line never costs the batch.
  class Batch
    extend T::Sig

    MAX_RECORDS = 20_000
    MAX_COUNT = 9_007_199_254_740_992 # 2**53, an integer JSON carries exactly
    VERSION = 1

    class Invalid < StandardError; end

    # The process that sent the batch, as its header describes it.
    class Header < T::Struct
      extend T::Sig

      const :kind, String
      const :host, String
      const :pid, Integer
      const :release, T.nilable(String)
      const :started_at, T.nilable(Time)
      const :runtime, T::Hash[String, T.untyped]
      const :dropped, T::Hash[String, Integer]

      # What every row this process sent starts with: when, whose, and
      # which process, host and release said it.
      sig { params(ts: Time, app_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def provenance(ts:, app_id:) = { ts: ts, app_id: app_id, process: kind, host: host, release: release }
    end

    sig { returns(Header) }
    attr_reader :header

    sig { returns(Integer) }
    attr_reader :skipped

    sig { returns(Clock) }
    attr_reader :clock

    sig { params(app: App, text: String, now: Time).returns(Batch) }
    def self.parse(app:, text:, now: Time.now.utc)
      # Line by line, so a body past the limit is refused at the line that
      # passes it rather than after the whole of it has been split.
      batch = T.let(nil, T.nilable(Batch))
      count = 0
      text.each_line(chomp: true) do |line|
        if batch.nil?
          raise Invalid, "Empty body" if line.strip.empty?

          batch = new(app: app, header: parse_header(line), clock: Clock.new(now: now))
          next
        end
        # A blank line is not a record, and does not count toward the limit.
        next if line.empty?
        raise Invalid, "More than #{MAX_RECORDS} records in one batch" if count >= MAX_RECORDS

        count += 1
        batch.add_line(line)
      end
      raise Invalid, "Empty body" if batch.nil?

      batch
    end

    sig { params(line: String).returns(Header) }
    def self.parse_header(line)
      doc = JSON.parse(line)
      raise Invalid, "Header must be a JSON object" unless doc.is_a?(Hash)
      raise Invalid, "Unsupported protocol version #{doc['v'].inspect}" unless doc["v"] == VERSION

      process = doc["process"]
      raise Invalid, "Header has no process" unless process.is_a?(Hash)

      started = Coerce.float(process["started_at"])
      dropped = doc["dropped"].is_a?(Hash) ? doc["dropped"] : {}
      Header.new(
        kind: Coerce.str(process["kind"], max: 40) || "web",
        host: Coerce.str(process["host"], max: 120) || "unknown",
        pid: Coerce.int(process["pid"]) || 0,
        release: Coerce.str(process["release"], max: 80),
        started_at: started ? Time.at(started).utc : nil,
        runtime: Coerce.attrs(process["runtime"]),
        dropped: dropped.first(20).to_h { |type, count| [ type.to_s[0, 20], Coerce.int(count, max: MAX_COUNT) || 0 ] }
      )
    rescue JSON::ParserError
      raise Invalid, "Header is not valid JSON"
    end
    private_class_method :parse_header

    sig { params(app: App, header: Header, clock: Clock).void }
    def initialize(app:, header:, clock:)
      @header = header
      @clock = clock
      @context = T.let(Records::Context.new(app_id: app.telemetry_id, header: header, clock: clock), Records::Context)
      @rows = T.let(Records::TYPES.keys.index_with { [] }, T::Hash[String, T::Array[T.untyped]])
      @skipped = T.let(0, Integer)
    end

    # What the records of one wire type became, in the order they came.
    sig { params(type: String).returns(T::Array[T.untyped]) }
    def rows(type) = @rows.fetch(type)

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def transactions = rows("txn")

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def spans = rows("span")

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def markers = rows("marker")

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def logs = rows("log")

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def pages = rows("page")

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def model_calls = rows("llm")

    sig { returns(T::Array[Records::Metric::Point]) }
    def metrics = rows("metric")

    sig { returns(T::Array[Records::Profile::Window]) }
    def profiles = rows("profile")

    sig { params(line: String).void }
    def add_line(line)
      return if line.empty?

      record = JSON.parse(line)
      return skip! unless record.is_a?(Hash)

      add_record(record)
    rescue JSON::ParserError
      skip!
    end

    # One decoded record. Public for callers that already hold records as
    # data (the demo generator replays history through the same builders).
    sig { params(record: T::Hash[String, T.untyped]).void }
    def add_record(record)
      type = record["t"]
      kind = Records::TYPES[type]
      row = kind && kind.build.call(record, @context)
      return skip! if row.nil?

      @rows.fetch(type) << row
    end

    sig { returns(Integer) }
    def accepted = @rows.sum { |_, list| list.size }

    private

    sig { void }
    def skip!
      @skipped += 1
    end
  end
end
