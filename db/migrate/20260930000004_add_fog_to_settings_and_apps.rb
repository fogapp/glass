# frozen_string_literal: true

# Level 1 of the fog integration: Glass reads fog through
# its MCP tools with a token the operator pastes in Settings.
class AddFogToSettingsAndApps < ActiveRecord::Migration[8.1]
  def change
    change_table :app_settings do |t|
      t.string :fog_url
      t.text :fog_token
      t.boolean :fog_sync_enabled, null: false, default: true
      t.datetime :fog_last_synced_at
      t.string :fog_last_error
      t.datetime :fog_last_tested_at
      t.boolean :fog_last_test_ok
      t.string :fog_last_test_message
    end
    # What fog last said about the app: rev, health, container id — so a
    # change between polls can be told from a poll.
    add_column :apps, :fog_state, :jsonb, null: false, default: {}
  end
end
