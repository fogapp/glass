# typed: strict
# frozen_string_literal: true

module ApiTokenSerializer
  extend T::Sig

  # Never the token itself: the plaintext exists once, in the create response.
  sig { params(token: ApiToken).returns(T::Hash[Symbol, T.untyped]) }
  def self.token_json(token)
    {
      id: token.id, name: token.name, prefix: token.prefix, scope: token.scope,
      expires_at: token.expires_at, expired: token.expired?, last_used_at: token.last_used_at,
      created_at: token.created_at
    }
  end
end
