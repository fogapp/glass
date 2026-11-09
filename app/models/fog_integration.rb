# typed: strict
# frozen_string_literal: true

# An app fog connected to Glass (FogIntegrations): the ingest key it reports
# with and the read-only API token it reads with, revoked together.
class FogIntegration < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :ingest_key, optional: true
  belongs_to :api_token, optional: true

  validates :consumer, presence: true
end
