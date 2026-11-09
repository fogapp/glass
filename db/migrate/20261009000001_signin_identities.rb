# frozen_string_literal: true

# Household sign-in (fog's docs/signin-contract.md). An identity is a
# verified sign-in from an OpenID provider — fog, or any other — linked to a
# Glass account; never matched by email. A session from one carries the
# provider's sid, so a back-channel logout can end exactly it, and a
# lifetime, so a missed logout heals by itself. A handoff is the one-time,
# one-minute code the callback gives the console to fetch its token with.
class SigninIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :identities, id: :uuid do |t|
      t.uuid :user_id, null: false
      t.string :issuer, null: false
      t.string :subject, null: false
      t.timestamps
    end
    add_index :identities, %i[issuer subject], unique: true
    add_index :identities, :subject
    add_index :identities, :user_id
    add_foreign_key :identities, :users, on_delete: :cascade

    add_column :api_sessions, :oidc_sid, :string
    add_column :api_sessions, :expires_at, :datetime
    add_column :api_sessions, :handoff_digest, :string
    add_column :api_sessions, :handoff_expires_at, :datetime
    add_index :api_sessions, :oidc_sid
    add_index :api_sessions, :handoff_digest, unique: true

    # When Glass last proved it runs on fog (FogClient::Signin::Proof): from
    # then on it signs people in through fog only.
    add_column :app_settings, :fog_attested_at, :datetime
  end
end
