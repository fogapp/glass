# typed: strict
# frozen_string_literal: true

module TriageSerializer
  extend T::Sig

  sig { params(report: Triage::Report, window: Triage::Window).returns(T::Hash[Symbol, T.untyped]) }
  def self.report_json(report, window)
    json = ->(finding) { finding_json(finding, report.dismissals[finding.subject.id]) }
    { from: window.from.to_f, to: window.to.to_f, baseline_from: window.baseline_from.to_f,
      findings: report.findings.map(&json), hidden: report.hidden.map(&json) }
  end

  # `dismissal` is someone's answer to it, if any: on a shown finding, one
  # that was dismissed and has got worse since.
  sig { params(finding: Triage::Finding, dismissal: T.nilable(TriageDismissal)).returns(T::Hash[Symbol, T.untyped]) }
  def self.finding_json(finding, dismissal = nil)
    subject = finding.subject
    { id: subject.id, kind: subject.kind.serialize, severity: finding.severity.serialize, score: finding.score,
      app: subject.app, work: subject.work, name: subject.name, title: finding.title, summary: finding.summary,
      figures: finding.figures, dismissal: dismissal && dismissal_json(dismissal, finding) }
  end

  # `regressed` only when the finding as it stands now is known.
  sig { params(dismissal: TriageDismissal, finding: T.nilable(Triage::Finding)).returns(T::Hash[Symbol, T.untyped]) }
  def self.dismissal_json(dismissal, finding = nil)
    { mode: dismissal.mode, score: dismissal.score, severity: dismissal.severity, at: dismissal.updated_at.to_f,
      by: dismissal.user&.name, regressed: finding ? dismissal.regressed?(finding) : false,
      returns_above: dismissal.mode_enum == TriageDismissal::Mode::Dismissed ? dismissal.score + TriageDismissal::REGRESSION_MARGIN : nil }
  end

  sig { params(detail: Triage::Detail, window: Triage::Window, dismissal: T.nilable(TriageDismissal)).returns(T::Hash[Symbol, T.untyped]) }
  def self.detail_json(detail, window, dismissal: nil)
    finding_json(detail.finding, dismissal).merge(
      from: window.from.to_f, to: window.to.to_f, baseline_from: window.baseline_from.to_f,
      description: detail.description,
      facts: detail.facts.map { |fact| { label: fact.label, value: fact.value } },
      evidence: detail.evidence.map { |evidence| evidence_json(evidence) },
      steps: detail.steps, source: detail.source, filter: detail.filter,
      brief: Triage::Brief.render(detail, window: window)
    )
  end

  sig { params(evidence: Triage::Evidence).returns(T::Hash[Symbol, T.untyped]) }
  def self.evidence_json(evidence)
    { type: evidence.type.serialize, title: evidence.title, note: evidence.note, query: evidence.query,
      columns: evidence.columns.map { |column| { key: column.key, label: column.label, unit: column.unit } },
      rows: evidence.rows }
  end
end
