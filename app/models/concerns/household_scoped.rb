# typed: strict
# frozen_string_literal: true

# Household tenancy:
# - default scope filters by Current.household *when set* — a no-op in jobs,
#   console, and seeds so background work sees everything;
# - household_id is always assigned from the authenticated context on create,
#   never from user input.
module HouseholdScoped
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    belongs_to :household
    validates :household_id, presence: true

    default_scope do
      Current.household ? where(household_id: Current.household.id) : all
    end

    before_validation :assign_household_from_current, on: :create
  end

  private

  # T.unsafe: household_id is a column on the *including* model, not on
  # ApplicationRecord — no way to express that in a shared concern.
  sig { void }
  def assign_household_from_current
    T.unsafe(self).household_id ||= Current.household&.id
  end
end
