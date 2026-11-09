# typed: strict
# frozen_string_literal: true

# What deserves attention across the fleet, ranked: the jobs that never
# finished, the endpoints that fail, the ones that got slower, the moments an
# app's endpoints stall together, where the time goes, the queries repeated
# per row, the queues that back up, the errors the logs keep saying, the
# monitors alerting, the pages that feel slow, the model calls that fail,
# the agents that went quiet.
#
# A finding is something to fix. Each detector holds itself to that: a
# number that is merely different, or small, or better than before is not
# listed — and a person dismissing a finding is a report that its detector
# drew the line in the wrong place.
#
# Every figure is read through the query engine (Query::Runner over
# Query::Context), so Triage sees exactly what the console and the MCP tools
# see and nothing a person could not ask for themselves. A finding names its
# subject, not a row: its id is the subject, and the detail is computed
# again from the subject over the range asked about — there is no table of
# findings to keep in step with the telemetry.
module Triage
  extend T::Sig

  # What kind of problem a finding is. The order is the console's legend.
  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Incident = new("incident")
      Stuck = new("stuck")
      Failing = new("failing")
      Regression = new("regression")
      Stall = new("stall")
      Reporting = new("reporting")
      Hotspot = new("hotspot")
      NPlusOne = new("n_plus_one")
      Queue = new("queue")
      LogErrors = new("log_errors")
      ModelErrors = new("model_errors")
      Vitals = new("vitals")
    end
  end

  class Severity < T::Enum
    include ApplicationEnum
    enums do
      Critical = new("critical")
      Warning = new("warning")
      Notice = new("notice")
    end
  end

  # What a finding is about: which detector found it, in which app, and the
  # thing itself — an endpoint, a job, a log message, a monitor. Its id is
  # this, encoded, so a link to a finding survives a reload and means the
  # same thing tomorrow.
  class Subject < T::Struct
    extend T::Sig

    const :kind, Kind
    const :app, T.nilable(String)
    # The kind of unit of work (request, job, run), the model's provider, a
    # route's method — whatever narrows `name` further. nil when nothing does.
    const :work, T.nilable(String)
    const :name, String

    sig { returns(String) }
    def id = Base64.urlsafe_encode64(JSON.generate([ kind.serialize, app, work, name ]), padding: false)

    sig { params(id: String).returns(T.nilable(Subject)) }
    def self.parse(id)
      kind, app, work, name = JSON.parse(Base64.urlsafe_decode64(id))
      parsed = Kind.try_deserialize(kind.to_s)
      return nil if parsed.nil? || !name.is_a?(String)
      # An id arrives in a URL and its app becomes a filter term: it must be
      # a slug. (Work and name are always quoted where they are used.)
      return nil unless app.nil? || (app.is_a?(String) && app.match?(App::SLUG_FORMAT))

      new(kind: parsed, app: app, work: work.is_a?(String) ? work : nil, name: name)
    rescue ArgumentError, JSON::ParserError, TypeError, NoMethodError
      nil
    end
  end

  # One thing worth fixing. `score` (0–100) ranks findings across kinds;
  # `figures` are the numbers the summary is made of, under stable keys.
  class Finding < T::Struct
    extend T::Sig

    const :subject, Subject
    const :score, Float
    const :title, String
    const :summary, String
    const :figures, T::Hash[String, T.untyped], default: {}

    sig { returns(Severity) }
    def severity
      if score >= 70 then Severity::Critical
      elsif score >= 40 then Severity::Warning
      else Severity::Notice
      end
    end
  end

  # The range being triaged, and the one it is compared with: the stretch
  # just before it, four times as long (at least a day, at most a fortnight)
  # so "before" is a habit rather than an hour.
  class Window < T::Struct
    extend T::Sig

    const :from, Time
    const :to, Time
    const :baseline_from, Time

    BASELINE_MIN = T.let(1.day, ActiveSupport::Duration)
    BASELINE_MAX = T.let(14.days, ActiveSupport::Duration)
    # The widest range triaged: every detector reads every row in it.
    MAX_RANGE = T.let(14.days, ActiveSupport::Duration)

    sig { params(from: Time, to: Time).returns(Window) }
    def self.around(from:, to:)
      raise Query::Invalid, "The range ends before it starts" if to <= from
      raise Query::Invalid, "Triage looks at most #{MAX_RANGE.in_days.to_i} days at once — narrow the range" if to - from > MAX_RANGE.to_f

      span = ((to - from) * 4).clamp(BASELINE_MIN.to_f, BASELINE_MAX.to_f)
      new(from: from, to: to, baseline_from: from.advance(seconds: -span))
    end

    sig { returns(Time) }
    def baseline_to = from

    # Whether the range reaches the present: "stopped reporting" and "open
    # incident" only mean something about now.
    sig { returns(T::Boolean) }
    def current? = to > 2.minutes.ago
  end

  # A finding, with what it rests on and what to do about it.
  class Detail < T::Struct
    extend T::Sig

    const :finding, Finding
    const :description, String
    const :facts, T::Array[Evidence::Fact]
    const :evidence, T::Array[Evidence]
    const :steps, T::Array[String]
    # The rows behind the finding, as a filter over `source` — the console
    # links it to the Explorer, an agent passes it to `query`.
    const :source, String
    const :filter, String

    # A detail, with only the evidence that holds something: a detector
    # lists every piece it might show, nil where one does not apply.
    sig do
      params(finding: Finding, description: String, facts: T::Array[Evidence::Fact], evidence: T::Array[T.nilable(Evidence)],
        steps: T::Array[String], source: String, filter: String).returns(Detail)
    end
    def self.build(finding:, description:, facts:, evidence:, steps:, source:, filter:)
      new(finding: finding, description: description, facts: facts, evidence: evidence.compact.reject(&:empty?), steps: steps,
        source: source, filter: filter)
    end
  end

  DETECTORS = T.let([
    Detectors::Incidents, Detectors::Stuck, Detectors::Failing, Detectors::Regression, Detectors::Stall, Detectors::Reporting,
    Detectors::Hotspot, Detectors::NPlusOne, Detectors::QueueWait, Detectors::LogErrors, Detectors::ModelErrors, Detectors::Vitals
  ].freeze, T::Array[T.class_of(Detector)])

  MAX_FINDINGS = 40

  # The list as a person sees it: what stands out, less what someone
  # dismissed or ignored — those are `hidden`, so the list can say so and
  # take them back. `dismissals` holds the answer for every finding that
  # has one, shown (dismissed, then worse) or hidden.
  class Report < T::Struct
    const :findings, T::Array[Finding]
    const :hidden, T::Array[Finding]
    const :dismissals, T::Hash[String, TriageDismissal]
  end

  # Everything worth a look, worst first. `context` is the asker's, when
  # the caller already resolved it.
  sig do
    params(household: Household, window: Window, app: T.nilable(String), context: T.nilable(Query::Context))
      .returns(T::Array[Finding])
  end
  def self.scan(household, window:, app: nil, context: nil)
    scan = Scan.new(household: household, window: window, app: app, context: context)
    findings = without_repeats(DETECTORS.flat_map { |detector| detector.new(scan).findings })
    findings.sort_by { |finding| [ -finding.score, finding.title ] }
  end

  # The scan, with the household's dismissals applied.
  sig { params(household: Household, window: Window, app: T.nilable(String), context: T.nilable(Query::Context)).returns(Report) }
  def self.report(household, window:, app: nil, context: nil)
    findings = scan(household, window: window, app: app, context: context)
    dismissals = household.triage_dismissals.where(finding_id: findings.map { |finding| finding.subject.id })
      .includes(:user).index_by(&:finding_id)
    hidden, shown = findings.partition { |finding| dismissals[finding.subject.id]&.hides?(finding) }
    Report.new(findings: shown.first(MAX_FINDINGS), hidden: hidden.first(MAX_FINDINGS), dismissals: dismissals)
  end

  # One finding as the list would have it: nil when its subject no longer
  # stands out over this range — fixed, or quiet, or never there.
  sig { params(household: Household, window: Window, subject: Subject).returns(T.nilable(Finding)) }
  def self.find(household, window:, subject:) = located(household, window: window, subject: subject)&.last

  # One finding, worked up; nil as for `find`.
  sig { params(household: Household, window: Window, subject: Subject).returns(T.nilable(Detail)) }
  def self.detail(household, window:, subject:)
    detector, finding = located(household, window: window, subject: subject)
    detector && finding && detector.detail(finding)
  end

  # The detector that finds `subject`, reading only it, and the finding it
  # makes of it — nil when it makes none.
  sig { params(household: Household, window: Window, subject: Subject).returns(T.nilable([ Detector, Finding ])) }
  def self.located(household, window:, subject:)
    detector_class = DETECTORS.find { |candidate| candidate.kind == subject.kind }
    detector = detector_class&.new(Scan.new(household: household, window: window, app: subject.app, subject: subject))
    finding = detector&.findings&.find { |candidate| candidate.subject.id == subject.id }
    detector && finding && [ detector, finding ]
  end
  private_class_method :located

  # A hotspot that is also a regression is one problem: the regression says
  # more (what changed, and since when).
  sig { params(findings: T::Array[Finding]).returns(T::Array[Finding]) }
  def self.without_repeats(findings)
    work = ->(finding) { [ finding.subject.app, finding.subject.work, finding.subject.name ] }
    regressed = findings.select { |finding| finding.subject.kind == Kind::Regression }.to_set { |finding| work.call(finding) }
    findings.reject { |finding| finding.subject.kind == Kind::Hotspot && regressed.include?(work.call(finding)) }
  end
  private_class_method :without_repeats
end
