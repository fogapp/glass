# typed: strict
# frozen_string_literal: true

# A verified sign-in from an OpenID provider — fog, or any other the
# household points OIDC_ISSUER at — linked to a Glass account
# (fog's docs/signin-contract.md). The pair (issuer, subject) is the key;
# an email address never is.
class Identity < ApplicationRecord
  belongs_to :user

  validates :issuer, :subject, presence: true
  validates :subject, uniqueness: { scope: :issuer }
end
