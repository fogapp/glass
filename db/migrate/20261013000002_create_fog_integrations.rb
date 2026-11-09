# frozen_string_literal: true

# fog-integration/1: one row per app fog connected to Glass, naming the two
# credentials minted for it — its ingest key and its read-only API token —
# so fog can report on and revoke them together.
class CreateFogIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :fog_integrations, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :ingest_key, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :api_token, type: :uuid, foreign_key: { on_delete: :nullify }
      # The fog app connected.
      t.string :consumer, null: false
      t.timestamps
    end
  end
end
