# typed: strict
# frozen_string_literal: true

class ActivityEntry < ApplicationRecord
  belongs_to :household, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  attribute :severity, Activity::Severity

  validates :source, :event, :summary, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
