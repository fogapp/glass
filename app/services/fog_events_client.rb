# typed: strict
# frozen_string_literal: true

# fog's household event stream (fog's docs/events-contract.md): Glass says what
# happened — an incident opened, a monitor recovered — and whoever reads the
# stream (HUD) decides what it deserves. Authenticated by the FOG_API_TOKEN
# fog injects into every app, so there is nothing to configure; off fog the
# variables are absent and there is no client. fogd is on the host, at the
# address fog itself injected (HouseholdUpstream).
class FogEventsClient
  extend T::Sig
  include UpstreamHttpClient
  include HouseholdUpstream

  sig { returns(T.nilable(FogEventsClient)) }
  def self.from_env
    return nil unless FogClient.available?

    new(base_url: T.must(FogClient.url), token: FogClient.token)
  end

  sig { override.returns(String) }
  def service_name = "fog events"

  # One CloudEvent. fog sets the source to this app; a retry with the same
  # id is absorbed there, so ids name the occurrence.
  sig { params(type: String, id: String, subject: String, data: T::Hash[String, T.untyped]).void }
  def publish(type:, id:, subject:, data:)
    response = http_post_json("#{base_url}/app/v1/events",
      body: { specversion: "1.0", id: id, type: type, subject: subject, time: Time.now.utc.iso8601, data: data })
    raise Error.new("fog answered #{response.status} to an event", status: response.status) unless response.status == 202
  end
end
