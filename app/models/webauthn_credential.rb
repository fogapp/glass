# typed: strict
# frozen_string_literal: true

# A passkey a member enrolled. The
# public key verifies assertions; sign_count catches a cloned authenticator.
class WebauthnCredential < ApplicationRecord
  belongs_to :user

  validates :external_id, presence: true, uniqueness: true
  validates :public_key, presence: true
  validates :nickname, length: { maximum: 80 }, allow_nil: true
end
