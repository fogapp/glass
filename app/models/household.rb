# typed: strict
# frozen_string_literal: true

# The one household this instance serves (one household, one
# box). Kept as a row rather than assumed so the auth stack, HouseholdScoped
# and the backup contract are the same code every sibling app runs.
class Household < ApplicationRecord
  extend T::Sig

  has_many :users, dependent: :destroy
  has_many :invite_codes, dependent: :destroy
  has_many :apps, dependent: :destroy
  has_many :dashboards, dependent: :destroy
  has_many :monitors, class_name: "MonitorRule", dependent: :destroy
  has_many :incidents, dependent: :destroy
  has_many :triage_dismissals, dependent: :destroy

  validates :name, presence: true

  # The household, or nil before setup. The oldest row, so the answer is
  # the same every time even if a second row ever appears (ids are UUIDs
  # and say nothing about order).
  sig { returns(T.nilable(Household)) }
  def self.instance = order(:created_at).first
end
