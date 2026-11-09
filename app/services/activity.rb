# typed: strict
# frozen_string_literal: true

# The operational timeline. One rule above
# all: RECORDING NEVER BREAKS THE OPERATION IT DESCRIBES — every write path
# rescues and logs. The silent-failure doctrine's other half: every rescue in
# app code routes *through* Activity.record(severity: Error) so nothing dies
# quietly.
module Activity
  extend T::Sig

  class Severity < T::Enum
    include ApplicationEnum
    enums do
      Info = new("info")
      Warn = new("warn")
      Error = new("error")
    end
  end

  sig do
    params(
      source: String,
      event: String,
      summary: String,
      severity: Severity,
      subject: T.nilable(ApplicationRecord),
      payload: T::Hash[T.untyped, T.untyped],
      duration_ms: T.nilable(Integer),
      household_id: T.nilable(String),
      exception: T.nilable(Exception)
    ).returns(T.nilable(ActivityEntry))
  end
  def self.record(source:, event:, summary:, severity: Severity::Info, subject: nil, payload: {}, duration_ms: nil, household_id: nil, exception: nil)
    # The Fog error-tracker bridge: a rescued exception recorded here is
    # still a bug someone should see, so hand it to Rails.error (the flare
    # gem subscribes; handled: true marks it as rescued). Unhandled crashes
    # reach the tracker without this — the bridge is for the rescues.
    report_exception(exception, source: source, event: event, severity: severity) if exception
    ActivityEntry.create!(
      household_id: household_id || Current.household&.id || household_of(subject),
      source: source,
      event: event,
      severity: severity.serialize,
      summary: summary.truncate(500),
      subject: subject,
      payload: payload,
      duration_ms: duration_ms,
      trace_id: Current.trace_id,
      created_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error("Activity.record failed (#{event}): #{e.class}: #{e.message}")
    nil
  end

  # The subject's household, for an entry recorded where neither the caller
  # nor Current names one (a job).
  sig { params(subject: T.nilable(ApplicationRecord)).returns(T.nilable(String)) }
  def self.household_of(subject)
    subject.has_attribute?(:household_id) ? T.unsafe(subject).household_id : nil if subject
  end
  private_class_method :household_of

  sig { params(exception: Exception, source: String, event: String, severity: Severity).void }
  def self.report_exception(exception, source:, event:, severity:)
    rails_severity = severity == Severity::Error ? :error : :warning
    Rails.error.report(exception, handled: true, severity: rails_severity, source: "activity",
      context: { source: source, event: event })
  rescue StandardError => e
    Rails.logger.error("Activity error report failed: #{e.class}: #{e.message}")
  end
  private_class_method :report_exception
end
