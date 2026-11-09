# typed: strict
# frozen_string_literal: true

# A long-lived, machine-facing credential —
# the sibling of ApiSession, which is minted by an interactive login and
# dies with it. Integrations and MCP clients hold these (DigestedToken).
#
# `scope` narrows what a token may do: `full` is its owner's access; `read`
# may look at everything and change nothing — the shape to hand an agent or
# a wall display.
class ApiToken < ApplicationRecord
  extend T::Sig
  include DigestedToken

  class Scope < T::Enum
    include ApplicationEnum
    enums do
      Full = new("full")
      Read = new("read")
    end
  end

  PREFIX = "glass_"
  MAX_NAME_LENGTH = 80
  MAX_EXPIRES_IN_DAYS = 3650

  belongs_to :user

  attribute :scope, Scope

  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  sig { override.returns(String) }
  def self.token_prefix = PREFIX

  sig { params(user: User, name: String, expires_at: T.nilable(Time), scope: Scope).returns(DigestedToken::Generated[T.attached_class]) }
  def self.generate(user:, name:, expires_at: nil, scope: Scope::Full)
    generate_with(user: user, name: name, expires_at: expires_at, scope: scope.serialize)
  end

  # nil for anything that isn't a live API token — including strings that
  # aren't API tokens at all, which fall through to ApiSession unqueried.
  sig { params(token: T.nilable(String)).returns(T.nilable(ApiToken)) }
  def self.authenticate(token) = find_by_token(active, token)

  sig { returns(T::Boolean) }
  def expired?
    expiry = expires_at
    expiry.present? && expiry.past?
  end

  sig { returns(T::Boolean) }
  def read_only? = scope_enum == Scope::Read
end
