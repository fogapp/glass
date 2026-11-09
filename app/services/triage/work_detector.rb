# typed: strict
# frozen_string_literal: true

module Triage
  # A detector whose subject is a unit of work — an endpoint, a job, an
  # agent — named by its app, its kind and its name: the same three columns
  # the console's endpoint pages and `slow_endpoints` group by.
  class WorkDetector < Detector
    extend T::Sig
    abstract!

    # [app, kind, name]
    Key = T.type_alias { T::Array[T.untyped] }

    # A p95 below this is not slow in its own right, whatever it was
    # before: a person waiting on a page does not feel it.
    SLOW_MS = 250.0
    # A job in the background is slow at a scale a person waiting on a
    # page is not.
    SLOW_JOB_MS = 5_000.0

    private

    # Whether a p95 is slow for its kind of work.
    sig { params(kind: T.untyped, p95: Float).returns(T::Boolean) }
    def slow?(kind, p95) = p95 >= (kind == "job" ? SLOW_JOB_MS : SLOW_MS)

    sig { override.params(subject: Subject).returns(String) }
    def subject_terms(subject) = [ Query::Filter.pair("kind", subject.work), Query::Filter.quote("name", subject.name) ].join(" ")

    sig { returns(T::Hash[Key, Row]) }
    def now = scan.work(narrow: narrow)

    sig { returns(T::Hash[Key, Row]) }
    def before = scan.work(narrow: narrow, baseline: true)

    # A detail's own figures, now and before: its scan reads only it.
    sig { returns(Row) }
    def subject_now = now.values.first || {}

    sig { returns(T.nilable(Row)) }
    def subject_before = before.values.first

    sig { params(key: Key).returns(Subject) }
    def work_subject(key)
      app, kind, name = key
      Subject.new(kind: self.class.kind, app: app, work: kind, name: name.to_s)
    end

    # "hook · SearchController#index"
    sig { params(subject: Subject).returns(String) }
    def label(subject) = [ subject.app, subject.name ].compact.join(" · ")

    sig { params(subject: Subject, row: Row).returns(T::Array[Evidence::Fact]) }
    def work_facts(subject, row)
      sample = scan.list(source: "transactions", filter: subject_filter(subject), limit: 1).first || {}
      releases = release_rows(subject).first(4)
      [
        fact("App", subject.app), fact("Kind", subject.work), fact("Name", subject.name),
        fact("Example path", [ sample["method"], sample["path"] ].compact.join(" ")),
        fact("Queue", sample["queue"]),
        fact("Count in range", Words.count(row["count"])),
        fact("Releases in range", releases.filter_map { |release| release["release"]&.to_s&.first(12) }.join(", "))
      ].compact
    end

    # The figures by release: whether one of them is the one that broke it.
    sig { params(subject: Subject).returns(Evidence) }
    def by_release(subject)
      table("By release", [ column("release", "Release", "sha"), column("count", "Count"), column("error_rate", "Error rate", "ratio"),
        column("p50(duration)", "p50", "ms"), column("p95(duration)", "p95", "ms") ], release_rows(subject))
    end

    # The subject's releases, busiest first — one reading for the facts and
    # the breakdown.
    sig { params(subject: Subject).returns(T::Array[Row]) }
    def release_rows(subject)
      scan.table(source: "transactions", group_by: %w[release], filter: subject_filter(subject), limit: 8,
        compute: [ "count", "error_rate", "p50(duration)", "p95(duration)" ])
    end

    # How the average splits into database, view, outbound and the app's
    # own code, now and before.
    PHASES = T.let(Telemetry::Work::PARTS.map { |part| [ "avg(#{part.name})", part.label ] }.freeze, T::Array[[ String, String ]])

    sig { params(current: Row, prior: T.nilable(Row)).returns(Evidence) }
    def phases(current, prior)
      rows = PHASES.filter_map do |key, name|
        next if current[key].nil? && prior&.dig(key).nil?

        { "phase" => name, "now" => current[key], "before" => prior&.dig(key) }
      end
      table("Where the time goes, on average", [ column("phase", "Phase"), column("now", "Now", "ms"), column("before", "Before", "ms") ],
        rows, note: "Averages per call. What the app's own code leaves is the time no phase accounts for.")
    end

    sig do
      params(finding: Finding, description: String, facts: T::Array[Evidence::Fact], evidence: T::Array[T.nilable(Evidence)],
        steps: T::Array[String]).returns(Detail)
    end
    def work_detail(finding, description:, facts:, evidence:, steps:)
      Detail.build(finding: finding, description: description, facts: facts, evidence: evidence, steps: steps,
        source: "transactions", filter: subject_filter(finding.subject))
    end
  end
end
