# typed: strict
# frozen_string_literal: true

module Triage
  # One way of noticing a problem. `findings` reads the scan's range and
  # says what crosses the line; `detail` works one of them up into what an
  # agent needs to fix it — the description, the facts, the evidence, the
  # steps. A detector run for one subject (Triage.detail) is handed a scan
  # narrowed to it, so its reading is the list's reading of that subject.
  class Detector
    extend T::Sig
    extend T::Helpers
    abstract!

    Row = T.type_alias { Scan::Row }

    sig { abstract.returns(Kind) }
    def self.kind; end

    sig { params(scan: Scan).void }
    def initialize(scan)
      @scan = scan
    end

    sig { abstract.returns(T::Array[Finding]) }
    def findings; end

    sig { abstract.params(finding: Finding).returns(Detail) }
    def detail(finding); end

    private

    sig { returns(Scan) }
    attr_reader :scan

    sig { returns(Window) }
    def window = scan.window

    # The filter terms that pick a subject's rows out of its app's: an
    # endpoint's kind and name, a log message at error level. nil for a
    # subject that is not a set of rows.
    sig { overridable.params(subject: Subject).returns(T.nilable(String)) }
    def subject_terms(subject) = nil

    # A subject's rows: its app's, narrowed by its terms.
    sig { params(subject: Subject).returns(String) }
    def subject_filter(subject) = [ subject.app && Query::Filter.pair("app", subject.app), subject_terms(subject) ].compact.join(" ")

    # A detail's scan reads only its subject; a scan of the fleet, all of it.
    sig { returns(T.nilable(String)) }
    def narrow = (subject = scan.subject) && subject_terms(subject)

    # How far `value` is towards `full`, 0–1.
    sig { params(value: T.untyped, full: Float).returns(Float) }
    def scale(value, full) = (value.to_f / full).clamp(0.0, 1.0)

    sig { params(subject: Subject, score: Numeric, title: String, summary: String, figures: Row).returns(Finding) }
    def finding(subject, score:, title:, summary:, figures: {})
      Finding.new(subject: subject, score: score.to_f.clamp(0.0, 100.0).round(1), title: title, summary: summary,
        figures: figures.transform_values { |value| value.is_a?(Float) && !value.finite? ? nil : value })
    end

    sig { params(label: String, value: T.untyped).returns(T.nilable(Evidence::Fact)) }
    def fact(label, value)
      text = value.to_s.strip
      text.empty? ? nil : Evidence::Fact.new(label: label, value: text)
    end

    sig { params(key: String, label: String, unit: T.nilable(String)).returns(Evidence::Column) }
    def column(key, label, unit = nil) = Evidence::Column.new(key: key, label: label, unit: unit)

    sig { params(title: String, query: Row, note: T.nilable(String)).returns(Evidence) }
    def chart(title, query, note: nil) = Evidence.new(type: Evidence::Type::Chart, title: title, query: query, note: note)

    sig { params(title: String, columns: T::Array[Evidence::Column], rows: T::Array[Row], note: T.nilable(String)).returns(Evidence) }
    def table(title, columns, rows, note: nil)
      keys = columns.map(&:key)
      Evidence.new(type: Evidence::Type::Table, title: title, columns: columns, rows: rows.map { |row| row.select { |key, _| keys.include?(key) } }, note: note)
    end

    TRACE_FIELDS = T.let(%w[ts app kind name trace status error http_status method path duration db db_count release kept].freeze,
      T::Array[String])

    sig { params(title: String, filter: String, order: T.nilable(String), limit: Integer, note: T.nilable(String)).returns(Evidence) }
    def traces(title, filter, order: nil, limit: 8, note: nil)
      rows = scan.list(source: "transactions", filter: filter, limit: limit, order: order)
      Evidence.new(type: Evidence::Type::Traces, title: title, note: note,
        rows: rows.map { |row| row.select { |key, value| TRACE_FIELDS.include?(key) && !value.nil? } })
    end

    sig { params(title: String, filter: String, limit: Integer, note: T.nilable(String)).returns(Evidence) }
    def logs(title, filter, limit: 12, note: nil)
      rows = scan.list(source: "logs", filter: filter, limit: limit)
      Evidence.new(type: Evidence::Type::Logs, title: title, note: note,
        rows: rows.map { |row| row.slice("ts", "app", "level", "message", "source", "release", "trace").compact })
    end

    MARKER_KINDS = T.let(%w[deploy restart incident].freeze, T::Array[String])

    # Deploys and restarts of the app from the start of the baseline: what
    # changed, and when.
    sig { params(app: T.nilable(String)).returns(Evidence) }
    def markers(app)
      found = app ? Markers.within(scan.context, from: window.baseline_from, to: window.to, limit: 12, app: app, kinds: MARKER_KINDS) : []
      rows = found.map do |marker|
        { "ts" => marker.ts.to_f, "kind" => marker.kind, "title" => marker.title, "release" => marker.release }.compact
      end
      Evidence.new(type: Evidence::Type::Markers, title: "Deploys and restarts", rows: rows,
        note: "From the start of the comparison window — a change that lines up with one is the first suspect.")
    end

    # A function holding less than this of the samples is not where the
    # time went.
    MIN_FUNCTION_SHARE = 0.01

    # Profile samples of an app's endpoints or jobs, by name.
    sig { params(app: T.nilable(String), names: T::Array[String]).returns(String) }
    def profile_filter(app, names) = [ app && "app:#{app}", Query::Filter.quote_any("transaction", names) ].compact.join(" ")

    # Where the profiler saw the time go for the samples `filter` picks (an
    # endpoint or job: profile_filter): the functions with the most self
    # time now, beside their share before.
    sig { params(filter: String).returns(Evidence) }
    def functions(filter)
      now = scan.top_functions(window.from, window.to, filter)
      before = scan.top_functions(window.baseline_from, window.baseline_to, filter).to_h { |row| [ [ row[:name], row[:file] ], row ] }
      rows = now.select { |row| row[:self_share].to_f >= MIN_FUNCTION_SHARE }.map do |row|
        prior = before[[ row[:name], row[:file] ]]
        { "name" => row[:name], "file" => row[:file], "line" => row[:line], "self_ms" => row[:self_ms], "self_share" => row[:self_share],
          "total_share" => row[:total_share], "before_share" => prior&.dig(:self_share) }.compact
      end
      Evidence.new(type: Evidence::Type::Functions, title: "Where the profiler saw the time", rows: rows,
        note: rows.empty? ? nil : "Self time — samples with the function on top of the stack — and its share before.")
    end
  end
end
