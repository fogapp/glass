# typed: strict
# frozen_string_literal: true

module Api
  module V1
    module Auth
      # Passkey sign-in. Runs without a session — it is how one is obtained.
      # Two phases (begin / finish): the server issues a challenge, signed
      # into a short-lived token the client round-trips, and the
      # authenticator's assertion is verified against the stored public key.
      class PasskeysController < ActionController::API
        extend T::Sig
        include WebauthnRelyingParty
        include LocalSignin

        rate_limit to: 10, within: 3.minutes
        local_signin_only

        rescue_from ActiveSupport::MessageVerifier::InvalidSignature, with: :challenge_expired

        # POST /api/v1/auth/passkey/login/begin — email optional; without it
        # the browser offers every discoverable passkey for this site.
        sig { void }
        def login_begin
          email = params[:email].to_s.strip.downcase.presence
          user = email ? User.find_by(email: email) : nil
          allowed = user ? user.webauthn_credentials.pluck(:external_id) : []
          options = WebAuthn::Credential.options_for_get(
            allow: allowed, user_verification: "preferred", relying_party: webauthn_relying_party
          )
          token = sign_challenge(intent: "login", challenge: options.challenge, email: email)
          render json: WebauthnCredentialSerializer.challenge_json(options, token)
        end

        # POST /api/v1/auth/passkey/login/finish — { credential, challenge_token }
        sig { void }
        def login_finish
          payload = read_challenge(intent: "login")
          assertion = WebAuthn::Credential.from_get(params.require(:credential), relying_party: webauthn_relying_party)
          stored = WebauthnCredential.find_by(external_id: assertion.id)
          return render_errors("That passkey isn't registered here", status: :unauthorized) if stored.nil?

          assertion.verify(payload["challenge"], public_key: stored.public_key, sign_count: stored.sign_count)
          stored.update!(sign_count: assertion.sign_count, last_used_at: Time.current)
          user = T.cast(stored.user, User)
          Activity.record(source: "auth", event: "passkey.signed_in", summary: "#{user.name} signed in with a passkey",
            subject: user, household_id: user.household_id)
          render_new_session(user, device: "passkey#{stored.nickname.present? ? " (#{stored.nickname})" : ''}")
        rescue WebAuthn::Error => e
          render_errors("Passkey verification failed: #{e.message}", status: :unauthorized)
        end

        private

        # Takes the exception because sorbet-runtime sig wrappers report
        # arity -1, so rescue_from passes it even to zero-param handlers.
        sig { params(_exception: T.untyped).void }
        def challenge_expired(_exception = nil)
          render_errors("The sign-in challenge expired — try again", status: :unauthorized)
        end
      end
    end
  end
end
