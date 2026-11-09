# typed: strict
# frozen_string_literal: true

# Builds a per-request WebAuthn::RelyingParty.
# The RP id is the host fog serves Glass on
# (GLASS_HOST), falling back to the request's host so development works on
# localhost; GLASS_WEBAUTHN_RP_ID / GLASS_WEBAUTHN_ORIGINS override both for
# setups where the API host isn't the page's domain.
#
# The RP id is what binds a passkey to the site; changing it invalidates
# every previously registered credential — which is why the fog-backup/2
# manifest carries it as identity.
module WebauthnRelyingParty
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::API }

  EXTRA_ALGORITHMS = T.let(%w[ES384 ES512 RS384 RS512 PS384 PS512].freeze, T::Array[String])
  CHALLENGE_TTL = T.let(5.minutes, ActiveSupport::Duration)

  included do
    T.bind(self, T.class_of(ActionController::API))
    before_action :load_webauthn!
  end

  # What the manifest records as identity: the RP id fog's host implies.
  sig { returns(T.nilable(String)) }
  def self.configured_rp_id
    ENV["GLASS_WEBAUTHN_RP_ID"].presence || GlassHost.host
  end

  private

  # The gem is `require: false` (Gemfile): loaded here, once per process,
  # by whichever request first touches a passkey.
  sig { void }
  def load_webauthn!
    require "webauthn"
  end

  sig { returns(T.untyped) }
  def webauthn_relying_party
    @webauthn_relying_party ||= T.let(begin
      rp_id = WebauthnRelyingParty.configured_rp_id || request.host
      WebAuthn::RelyingParty.new(
        id: rp_id,
        name: "Glass",
        allowed_origins: webauthn_allowed_origins(rp_id),
        algorithms: WebAuthn::RelyingParty::DEFAULT_ALGORITHMS + EXTRA_ALGORITHMS
      )
    end, T.untyped)
  end

  # A stable, opaque user handle derived from the user's id — never the
  # email, which the spec says must not be the handle.
  sig { params(user: User).returns(String) }
  def webauthn_user_handle(user)
    Base64.urlsafe_encode64(
      OpenSSL::HMAC.digest("SHA256", Rails.application.secret_key_base, "webauthn-uid:#{user.id}")
    )
  end

  sig { params(payload: T::Hash[Symbol, T.untyped]).returns(String) }
  def sign_challenge(payload)
    Rails.application.message_verifier(:webauthn).generate(
      payload.merge(issued_at: Time.current.to_i), expires_in: CHALLENGE_TTL
    )
  end

  # Raises MessageVerifier::InvalidSignature on an expired/tampered token;
  # includers map it to their own status.
  sig { params(intent: String).returns(T::Hash[String, T.untyped]) }
  def read_challenge(intent:)
    token = params.require(:challenge_token).to_s
    payload = Rails.application.message_verifier(:webauthn).verify(token)
    payload = payload.to_h.stringify_keys if payload.respond_to?(:to_h)
    raise WebAuthn::Error, "intent mismatch" unless payload.is_a?(Hash) && payload["intent"] == intent

    payload
  end

  sig { params(user: User).returns(T.untyped) }
  def creation_options_for(user)
    WebAuthn::Credential.options_for_create(
      user: { id: webauthn_user_handle(user), name: user.email, display_name: user.name.presence || user.email },
      exclude: user.webauthn_credentials.pluck(:external_id),
      authenticator_selection: { user_verification: "preferred", resident_key: "preferred" },
      relying_party: webauthn_relying_party
    )
  end

  # The API's own origin covers production (same origin behind fog's
  # proxy). The Origin header covers development, where the Vite page on
  # 5174 calls the API on 3002 — admitted only when its host matches the RP
  # id, since the browser's rp_id-vs-page-domain check is what anchors
  # phishing protection.
  sig { params(rp_id: String).returns(T::Array[String]) }
  def webauthn_allowed_origins(rp_id)
    configured = ENV["GLASS_WEBAUTHN_ORIGINS"].presence
    return configured.split(",").map(&:strip) if configured

    origins = [ request.base_url ]
    header = request.headers["Origin"].presence
    if header
      host = begin
        URI.parse(header).host
      rescue URI::InvalidURIError
        nil
      end
      origins << header if host == rp_id
    end
    origins.uniq
  end
end
