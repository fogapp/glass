# typed: strict
# frozen_string_literal: true

class User < ApplicationRecord
  extend T::Sig

  # Roles: admins own the instance (apps and ingest keys, fog,
  # retention, invites); members build dashboards, views and monitors;
  # guests are read-only.
  class Role < T::Enum
    include ApplicationEnum
    enums do
      Admin = new("admin")
      Member = new("member")
      Guest = new("guest")
    end
  end

  belongs_to :household
  has_many :api_sessions, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :webauthn_credentials, dependent: :destroy
  # Sign-ins from an OpenID provider linked to this account (fog sign-in).
  has_many :identities, dependent: :destroy

  has_secure_password

  attribute :role, Role

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP, message: "must be a valid email address" }
  validates :name, presence: true
  validates :password, length: { minimum: 10 }, allow_nil: true

  # An account: the setup wizard's first admin, an invite's member, the
  # demo's dev login — and someone fog signs in, under a random password no
  # one is told (SigninAdapter).
  sig { params(household: Household, email: String, name: String, password: String, role: Role).returns(User) }
  def self.register!(household:, email:, name:, password:, role:)
    household.users.create!(email: email, name: name, password: password, role: role.serialize)
  end

  sig { returns(T::Boolean) }
  def admin?
    role_enum == Role::Admin
  end

  sig { returns(T::Boolean) }
  def guest?
    role_enum == Role::Guest
  end
end
