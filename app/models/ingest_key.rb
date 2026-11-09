# typed: strict
# frozen_string_literal: true

# The credential an app reports with: `GLASS_API_KEY`. Write-only and
# app-scoped — it can submit telemetry for its one app and read nothing.
# A DigestedToken like ApiToken, with its own prefix so the
# two can never be confused for one another.
class IngestKey < ApplicationRecord
  extend T::Sig
  include DigestedToken

  PREFIX = "glass_ing_"

  belongs_to :app

  validates :name, presence: true, length: { maximum: 80 }

  scope :active, -> { where(revoked_at: nil) }

  sig { override.returns(String) }
  def self.token_prefix = PREFIX

  sig { params(app: App, name: String).returns(DigestedToken::Generated[T.attached_class]) }
  def self.generate(app:, name:) = generate_with(app: app, name: name)

  # nil for anything that is not a live ingest key.
  sig { params(token: T.nilable(String)).returns(T.nilable(IngestKey)) }
  def self.authenticate(token) = find_by_token(active.includes(:app), token)

  sig { returns(T::Boolean) }
  def revoked? = revoked_at.present?

  sig { void }
  def revoke!
    update!(revoked_at: Time.current) unless revoked?
  end
end
