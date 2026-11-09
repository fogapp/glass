# typed: strict
# frozen_string_literal: true

# A person's answer to a triage finding (Triage::Subject#id). A dismissed
# finding stays out of the list until it is worse than when it was
# dismissed — a higher severity, or a score REGRESSION_MARGIN above; an
# ignored one stays out whatever it does. Either way it is one click from
# coming back: the list says what it hides.
class TriageDismissal < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class Mode < T::Enum
    include ApplicationEnum
    enums do
      Dismissed = new("dismissed")
      Ignored = new("ignored")
    end
  end

  # How many points of score a dismissed finding must gain to come back:
  # enough that the ordinary wobble of a range does not count as worse.
  REGRESSION_MARGIN = 10.0

  belongs_to :user, optional: true

  attribute :mode, Mode
  attribute :severity, Triage::Severity

  validates :finding_id, presence: true
  validates :title, presence: true

  # Dismiss or ignore `finding`, remembering how bad it was.
  sig { params(household: Household, finding: Triage::Finding, mode: Mode, user: T.nilable(User)).returns(TriageDismissal) }
  def self.record!(household, finding, mode:, user:)
    dismissal = unscoped.find_or_initialize_by(household_id: household.id, finding_id: finding.subject.id)
    dismissal.update!(mode: mode.serialize, user: user, score: finding.score, severity: finding.severity.serialize,
      title: finding.title.first(300))
    dismissal
  end

  # Whether `finding` is out of the list because of this.
  sig { params(finding: Triage::Finding).returns(T::Boolean) }
  def hides?(finding) = mode_enum == Mode::Ignored || !regressed?(finding)

  # Whether a dismissed finding is worse now than when it was dismissed.
  sig { params(finding: Triage::Finding).returns(T::Boolean) }
  def regressed?(finding)
    return false unless mode_enum == Mode::Dismissed

    finding.score >= score + REGRESSION_MARGIN || severity_rank(finding.severity) > severity_rank(severity_enum)
  end

  private

  sig { params(severity: Triage::Severity).returns(Integer) }
  def severity_rank(severity) = Triage::Severity.values.reverse.index(severity) || 0
end
