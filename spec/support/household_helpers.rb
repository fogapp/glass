# typed: false
# frozen_string_literal: true

# The household almost every spec starts from, for every spec type — model,
# job, service and request specs alike write `let(:household) { create_household }`.
module HouseholdHelpers
  def create_household(name: "Test Household")
    Household.create!(name: name)
  end
end

RSpec.configure do |config|
  config.include HouseholdHelpers
end
