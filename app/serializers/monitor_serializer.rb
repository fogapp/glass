# typed: strict
# frozen_string_literal: true

module MonitorSerializer
  extend T::Sig

  # The open incident comes from `open_incidents`: preload it where monitors
  # are listed; a single monitor asks for it with one LIMIT 1.
  sig { params(monitor: MonitorRule, incidents: T.nilable(T::Array[Incident])).returns(T::Hash[Symbol, T.untyped]) }
  def self.monitor_json(monitor, incidents: nil)
    {
      id: monitor.id, name: monitor.name, description: monitor.description, enabled: monitor.enabled, kind: monitor.kind,
      query: monitor.query, comparison: monitor.comparison, threshold: monitor.threshold, window_seconds: monitor.window_seconds,
      for_seconds: monitor.for_seconds, deploy_grace_seconds: monitor.deploy_grace_seconds, notify: monitor.notify,
      state: monitor.state, state_since: monitor.state_since, last_value: monitor.last_value, last_evaluated_at: monitor.last_evaluated_at,
      last_error: monitor.last_error, condition: monitor.condition_text, app: monitor.app_slug,
      open_incident: (open = monitor.open_incidents.first) && incident_json(open),
      incidents: incidents&.map { |incident| incident_json(incident) }
    }.compact
  end

  sig { params(incident: Incident).returns(T::Hash[Symbol, T.untyped]) }
  def self.incident_json(incident)
    { id: incident.id, monitor_id: incident.monitor_id, opened_at: incident.opened_at, closed_at: incident.closed_at,
      peak_value: incident.peak_value, app: incident.app_slug, notified_at: incident.notified_at }
  end
end
