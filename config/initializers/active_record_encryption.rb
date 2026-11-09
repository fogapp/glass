# typed: true
# frozen_string_literal: true

# Encryption keys come from env vars (fog injects them as app secrets), never
# from credentials.yml. Development and test fall back to fixed
# throwaway keys so `bin/rails` works with zero setup; production requires all
# three (and SECRET_KEY_BASE) or fails to boot.
Rails.application.config.active_record.encryption.tap do |enc|
  if Rails.env.production?
    enc.primary_key = ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY")
    enc.deterministic_key = ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY")
    enc.key_derivation_salt = ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT")
  else
    enc.primary_key = ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY", "glass-dev-primary-key")
    enc.deterministic_key = ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY", "glass-dev-deterministic-key")
    enc.key_derivation_salt = ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT", "glass-dev-salt")
  end
  # Credentials rows predating an encryption rollout read as plaintext and
  # re-encrypt on next save instead of raising.
  enc.support_unencrypted_data = true
end
