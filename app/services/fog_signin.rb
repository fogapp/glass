# typed: strict
# frozen_string_literal: true

# Whether Glass signs people in through an OpenID provider, and whether it
# does so exclusively (fog's docs/signin-contract.md). Only the
# console's people: ingest keys and API tokens are untouched by any of it.
#
# Fog-only is earned, not configured: Glass turns its own sign-in off only
# after proving it runs on fog — the fog that recognises Glass's own
# FOG_API_TOKEN signs, with the key that signs Glass's ID tokens, the issuer
# and client Glass is configured with. Once proven it stays on: a later
# failure to reach fog never re-opens local passwords, or blocking fogd
# would be a way to switch them back. It ends only when the FOG_* variables
# are gone (Glass was taken off fog) — and the console's recovery link
# (bin/rails glass:recovery_link) is always there for a broken fog.
module FogSignin
  extend T::Sig

  # The proof is asked for from the unauthenticated setup status, which the
  # login page loads; until it succeeds, one process asks fog at most this
  # often, so reloading the login page cannot fan out to fogd.
  RETRY_EVERY = T.let(30.seconds, ActiveSupport::Duration)

  @attempted_at = T.let(nil, T.nilable(ActiveSupport::TimeWithZone))
  @mutex = T.let(Mutex.new, Mutex)

  sig { returns(T::Boolean) }
  def self.enabled? = FogClient::Signin.enabled?

  sig { returns(T::Boolean) }
  def self.fog_only?
    enabled? && !FogClient.url.nil? && AppSetting.cached.fog_attested_at.present?
  end

  # Prove it now if it has not been proven yet. Cheap once proven; called
  # where the console asks how to sign in.
  sig { void }
  def self.attest_if_needed
    return if !enabled? || FogClient.url.nil? || AppSetting.cached.fog_attested_at.present?

    config = FogClient::Signin.config
    return if config.nil?
    return unless claim_attempt!
    return unless FogClient::Signin::Proof.check(FogClient::Signin::Rails.provider_for(config))

    AppSetting.current.update!(fog_attested_at: Time.current)
    Activity.record(source: "auth", event: "fog_only", household_id: Household.instance&.id,
      summary: "Glass proved it runs on fog (#{config.issuer}); from now on everyone signs in to the console with fog")
  end

  # For specs: forget when this process last asked.
  sig { void }
  def self.reset_attempts!
    @mutex.synchronize { @attempted_at = nil }
  end

  sig { returns(T::Boolean) }
  def self.claim_attempt!
    @mutex.synchronize do
      last = @attempted_at
      next false if last && last > RETRY_EVERY.ago

      @attempted_at = Time.current
      true
    end
  end
  private_class_method :claim_attempt!
end
