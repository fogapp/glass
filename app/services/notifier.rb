# typed: strict
# frozen_string_literal: true

# Pushes to whatever Settings › Notifications has: ntfy today. A push is a
# nicety on top of the durable incident row, so a failure is recorded and
# swallowed.
module Notifier
  extend T::Sig

  sig { params(title: String, message: String).void }
  def self.push(title:, message:)
    client = NtfyClient.for(AppSetting.cached)
    return if client.nil?

    client.publish(title: title, message: message)
  rescue UpstreamHttpClient::Error => e
    Activity.record(source: "notifications", event: "push.failed", severity: Activity::Severity::Warn,
      summary: "ntfy push failed: #{e.message}", exception: e)
  end
end
