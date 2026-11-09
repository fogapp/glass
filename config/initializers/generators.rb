# typed: true
# frozen_string_literal: true

# UUID primary keys everywhere (pgcrypto's gen_random_uuid).
Rails.application.config.generators do |g|
  g.orm :active_record, primary_key_type: :uuid
end
