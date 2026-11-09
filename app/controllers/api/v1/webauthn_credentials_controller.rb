# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The signed-in member's passkeys: enrol (begin/finish), list, remove.
    # Removing the last one is fine — password sign-in is always there.
    class WebauthnCredentialsController < BaseController
      include WebauthnRelyingParty

      # A guest manages their own passkeys like anyone else.
      skip_before_action :deny_guest_writes

      sig { void }
      def index
        render json: current_user!.webauthn_credentials.order(:created_at).map { |c| WebauthnCredentialSerializer.credential_json(c) }
      end

      # POST /api/v1/webauthn_credentials/register/begin
      sig { void }
      def register_begin
        options = creation_options_for(current_user!)
        token = sign_challenge(intent: "register", challenge: options.challenge, user_id: current_user!.id)
        render json: WebauthnCredentialSerializer.challenge_json(options, token)
      end

      # POST /api/v1/webauthn_credentials/register/finish — { credential, challenge_token, nickname? }
      sig { void }
      def register_finish
        payload = read_challenge(intent: "register")
        return render_errors("That challenge belongs to another account", status: :forbidden) unless payload["user_id"] == current_user!.id

        attestation = WebAuthn::Credential.from_create(params.require(:credential), relying_party: webauthn_relying_party)
        attestation.verify(payload["challenge"])
        credential = current_user!.webauthn_credentials.create!(
          external_id: attestation.id, public_key: attestation.public_key, sign_count: attestation.sign_count,
          nickname: params[:nickname].to_s.strip.presence
        )
        Activity.record(source: "auth", event: "passkey.enrolled",
          summary: "#{current_user!.name} added a passkey#{credential.nickname ? " (#{credential.nickname})" : ''}",
          subject: current_user!)
        render json: WebauthnCredentialSerializer.credential_json(credential), status: :created
      rescue WebAuthn::Error => e
        render_errors("Passkey verification failed: #{e.message}")
      end

      sig { void }
      def destroy
        credential = current_user!.webauthn_credentials.find(params.require(:id).to_s)
        credential.destroy!
        Activity.record(source: "auth", event: "passkey.removed",
          summary: "#{current_user!.name} removed a passkey#{credential.nickname ? " (#{credential.nickname})" : ''}",
          subject: current_user!)
        head :no_content
      end

      private

      # An expired token must become a WebAuthn::Error so register_finish's
      # ceremony rescue renders the 422 instead of a generic 500.
      sig { params(intent: String).returns(T::Hash[String, T.untyped]) }
      def read_challenge(intent:)
        super
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        raise WebAuthn::Error, "challenge expired or invalid"
      end
    end
  end
end
