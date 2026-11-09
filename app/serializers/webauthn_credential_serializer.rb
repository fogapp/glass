# typed: strict
# frozen_string_literal: true

module WebauthnCredentialSerializer
  extend T::Sig

  sig { params(credential: WebauthnCredential).returns(T::Hash[Symbol, T.untyped]) }
  def self.credential_json(credential)
    {
      id: credential.id, nickname: credential.nickname,
      created_at: credential.created_at, last_used_at: credential.last_used_at
    }
  end

  # A passkey ceremony's opening move: the browser's WebAuthn options and
  # the signed challenge the finish call hands back.
  sig { params(options: T.untyped, challenge_token: String).returns(T::Hash[Symbol, T.untyped]) }
  def self.challenge_json(options, challenge_token)
    { options: options.as_json, challenge_token: challenge_token }
  end
end
