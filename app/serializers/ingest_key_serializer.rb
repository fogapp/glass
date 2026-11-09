# typed: strict
# frozen_string_literal: true

module IngestKeySerializer
  extend T::Sig

  # Never the key itself: the plaintext exists once, in the create response.
  sig { params(key: IngestKey).returns(T::Hash[Symbol, T.untyped]) }
  def self.key_json(key)
    {
      id: key.id, name: key.name, prefix: key.prefix, last_used_at: key.last_used_at,
      revoked_at: key.revoked_at, revoked: key.revoked?, created_at: key.created_at
    }
  end
end
