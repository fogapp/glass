# typed: strict
# frozen_string_literal: true

# A stretch of time a monitor was alerting.
class Incident < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :monitor, class_name: "MonitorRule", inverse_of: :incidents

  scope :open, -> { where(closed_at: nil) }

  sig { returns(T::Boolean) }
  def open? = closed_at.nil?
end
