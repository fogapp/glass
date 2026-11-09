# typed: strict
# frozen_string_literal: true

# What Glass tells fog's event stream. Published for every incident, whether
# or not the monitor pushes to ntfy: the reader decides what an event
# deserves, and `notify` rides along for a rule that wants to agree with the
# monitor. Opened and closed share a `key`, so a reader that keys by it (HUD
# does) ends the incident's notice when the incident closes.
module FogEvents
  extend T::Sig

  sig { params(incident: Incident, monitor: MonitorRule, value: T.nilable(Float)).void }
  def self.incident_opened(incident, monitor, value)
    publish("glass.incident.opened", incident, monitor,
      title: "Glass: #{monitor.name}",
      body: "#{monitor.condition_text} — now #{value&.round(3) || 'no data'}",
      value: value)
  end

  sig { params(incident: Incident, monitor: MonitorRule).void }
  def self.incident_closed(incident, monitor)
    publish("glass.incident.closed", incident, monitor,
      title: "Glass: #{monitor.name} recovered", body: monitor.condition_text, value: incident.peak_value)
  end

  sig do
    params(type: String, incident: Incident, monitor: MonitorRule, title: String, body: String, value: T.nilable(Float)).void
  end
  def self.publish(type, incident, monitor, title:, body:, value:)
    client = FogEventsClient.from_env
    return if client.nil?

    phase = type.split(".").last
    client.publish(type: type, id: "incident-#{incident.id}-#{phase}", subject: monitor.name, data: {
      "key" => "incident-#{incident.id}", "title" => title, "body" => body, "link" => link(monitor),
      "monitor" => monitor.name, "monitor_id" => monitor.id, "app" => incident.app_slug,
      "condition" => monitor.condition_text, "value" => value, "notify" => monitor.notify
    }.compact)
  rescue UpstreamHttpClient::Error => e
    Activity.record(source: "notifications", event: "event.failed", severity: Activity::Severity::Warn,
      summary: "fog event failed: #{e.message}", exception: e)
  end
  private_class_method :publish

  sig { params(monitor: MonitorRule).returns(T.nilable(String)) }
  def self.link(monitor)
    origin = GlassHost.origin
    origin && "#{origin}/monitors/#{monitor.id}"
  end
  private_class_method :link
end
