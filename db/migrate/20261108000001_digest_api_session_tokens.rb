# frozen_string_literal: true

# A console session's bearer token was kept as it is, so every backup of the
# primary database held working credentials. Keep only its digest, as
# ApiToken, IngestKey and the handoff code already do. The digest is
# DigestedToken.digest — lowercase hex SHA-256 of the token's bytes — which
# Postgres computes identically, so outstanding sessions keep working.
class DigestApiSessionTokens < ActiveRecord::Migration[8.1]
  def up
    add_column :api_sessions, :token_digest, :string
    execute <<~SQL.squish
      UPDATE api_sessions SET token_digest = encode(sha256(convert_to(token, 'UTF8')), 'hex')
    SQL
    change_column_null :api_sessions, :token_digest, false
    add_index :api_sessions, :token_digest, unique: true
    remove_index :api_sessions, :token
    remove_column :api_sessions, :token
  end

  # The plaintexts are gone; there is nothing to put back.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
