# typed: strict
# frozen_string_literal: true

# The ntfy push relay, through the shared client like every other egress, so
# it gets the same timeouts, circuit breaker and typed errors. Publishes as
# JSON to the server root (ntfy's "publish as JSON"), which carries the topic
# and title in the body rather than in the path and headers. The server is
# the one an admin entered in Settings — fog's ntfy on the fog network
# (http://ntfy), a private address by design (HouseholdUpstream); an ntfy
# access token (tk_…) rides as the bearer, and a public topic needs none.
class NtfyClient
  extend T::Sig
  include UpstreamHttpClient
  include HouseholdUpstream

  # The client for the ntfy server entered in Settings, nil until one is.
  sig { params(setting: AppSetting).returns(T.nilable(NtfyClient)) }
  def self.for(setting)
    url = setting.ntfy_url.presence
    return nil if url.nil?

    new(base_url: url, topic: setting.ntfy_topic.presence || "glass", token: setting.ntfy_token.presence)
  end

  sig { params(base_url: String, topic: String, token: T.nilable(String)).void }
  def initialize(base_url:, topic:, token: nil)
    super(base_url: base_url, token: token)
    @topic = topic
  end

  sig { override.returns(String) }
  def service_name = "ntfy"

  sig { returns(String) }
  attr_reader :topic

  sig { params(title: String, message: String).void }
  def publish(title:, message:)
    http_post_json("#{base_url}/", body: { topic: @topic, title: title, message: message })
  end

  # Settings' Test button. ntfy has no dry-run publish, and its only probe
  # (GET /<topic>/auth) checks *read* access — a write-only token, the
  # least a push sender needs, would fail it while pushes worked. So the
  # test publishes one message: the only call that proves the thing Glass
  # needs, and the operator sees it arrive.
  sig { returns([ T::Boolean, String ]) }
  def test_connection
    publish(title: "Glass: test", message: "Glass can push to this topic.")
    [ true, "Published a test push to “#{@topic}” — it should be on your devices now." ]
  end
end
