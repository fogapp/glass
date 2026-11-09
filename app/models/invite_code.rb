# typed: strict
# frozen_string_literal: true

class InviteCode < ApplicationRecord
  extend T::Sig

  DEFAULT_TTL = T.let(7.days, ActiveSupport::Duration)

  belongs_to :household
  belongs_to :created_by, class_name: "User", optional: true

  attribute :role, User::Role

  validates :code, presence: true, uniqueness: true
  validates :expires_at, presence: true

  sig { params(household: Household, created_by: User, role: User::Role).returns(InviteCode) }
  def self.generate!(household:, created_by:, role: User::Role::Member)
    create!(
      household: household,
      created_by: created_by,
      role: role.serialize,
      code: SecureRandom.alphanumeric(24),
      expires_at: DEFAULT_TTL.from_now
    )
  end

  # Raised when a consume! loses the race for the single use. An invite is a
  # household-admission credential, so "who redeems it" must be decided by
  # the database, not by whichever request read it first.
  class AlreadyUsed < StandardError; end

  sig { returns(T::Boolean) }
  def usable?
    used_at.nil? && expires_at.after?(Time.current)
  end

  # A conditional UPDATE is the guard: two concurrent accepts can both pass
  # usable?, but only one matches the unused row. The loser raises, rolling
  # back its half-created user.
  sig { void }
  def consume!
    claimed = self.class.where(id: id, used_at: nil)
      .where(expires_at: Time.current..)
      .update_all(used_at: Time.current)
    raise AlreadyUsed, "Invite already used or expired" if claimed.zero?

    reload
  end
end
