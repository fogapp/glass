# typed: strict
# frozen_string_literal: true

# One row per signed-in client. Opaque
# tokens, of which only the digest is kept (DigestedToken.digest): the
# plaintext exists on the instance that minted it and nowhere else, so a
# backup of the primary database holds no working credential. Revocation is
# row deletion (logout / settings). A session from a
# password, a passkey, setup or an invite never expires; one from fog
# sign-in lives no longer than FOG_TTL, and fog's back-channel logout ends
# it by its sid.
class ApiSession < ApplicationRecord
  extend T::Sig
  include UseStamped

  # A session from fog sign-in lives no longer than the fog session behind
  # it; back-channel logout usually ends it sooner, and this is what heals a
  # logout that never arrived (fog's docs/signin-contract.md).
  FOG_TTL = T.let(30.days, ActiveSupport::Duration)
  # The callback hands the console a code, not the token: the code rides in
  # a URL fragment for one redirect and is good once, for a minute.
  HANDOFF_TTL = T.let(1.minute, ActiveSupport::Duration)

  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true

  # The bearer token in plaintext — set only on the instance that minted it
  # (generate!, redeem_handoff), for the one response that hands it over.
  # Never a column: a session read back from the database has none.
  sig { returns(T.nilable(String)) }
  def token
    @token = T.let(@token, T.nilable(String))
  end

  # This instance, carrying `token` in memory for the response that hands it
  # over. Nothing is written.
  sig { params(token: String).returns(T.self_type) }
  def carrying(token)
    @token = token
    self
  end

  sig { params(token: String).returns(String) }
  def self.digest(token) = DigestedToken.digest(token)

  sig { returns(String) }
  def self.mint_token = SecureRandom.hex(32)

  sig do
    params(user: User, device: T.nilable(String), oidc_sid: T.nilable(String),
      expires_at: T.nilable(ActiveSupport::TimeWithZone)).returns(ApiSession)
  end
  def self.generate!(user:, device: nil, oidc_sid: nil, expires_at: nil)
    token = mint_token
    session = create!(user: user, token_digest: digest(token), device: device, last_used_at: Time.current,
      oidc_sid: oidc_sid, expires_at: expires_at)
    session.carrying(token)
  end

  # The live session for a bearer token: an expired one reads as none, and
  # is removed on the way.
  sig { params(token: String).returns(T.nilable(ApiSession)) }
  def self.live(token)
    session = find_by(token_digest: digest(token))
    return session unless session&.expired?

    session.destroy
    nil
  end

  sig { returns(T::Boolean) }
  def expired?
    at = expires_at
    !at.nil? && at <= Time.current
  end

  # A one-time code the console exchanges for this session's token. Only its
  # digest is kept.
  sig { params(ttl: ActiveSupport::Duration).returns(String) }
  def issue_handoff!(ttl: HANDOFF_TTL)
    code = SecureRandom.urlsafe_base64(32)
    update!(handoff_digest: digest(code), handoff_expires_at: ttl.from_now)
    code
  end

  # The session a handoff code names — once: two racing redemptions cannot
  # both win, because the database spends the code. Its plaintext token was
  # never kept, so spending the code also gives the session a fresh one,
  # which the returned instance carries for the response that hands it over.
  sig { params(code: String).returns(T.nilable(ApiSession)) }
  def self.redeem_handoff(code)
    return nil if code.blank?

    handoff = digest(code)
    session = find_by(handoff_digest: handoff)
    return nil if session.nil?

    token = mint_token
    spent = where(id: session.id, handoff_digest: handoff).where("handoff_expires_at > ?", Time.current)
      .update_all(handoff_digest: nil, handoff_expires_at: nil, token_digest: digest(token)) # rubocop:disable Rails/SkipsModelValidations
    return nil unless spent == 1 && !session.expired?

    session.carrying(token)
  end

  private

  sig { params(code: String).returns(String) }
  def digest(code) = self.class.digest(code)
end
