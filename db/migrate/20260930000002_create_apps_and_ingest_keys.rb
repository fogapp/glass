# frozen_string_literal: true

# The things that report, and the credentials they report with.
class CreateAppsAndIngestKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :apps, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # Telemetry rows name their app by this 4-byte number rather than by
      # uuid: it is on every row of every signal table and in most of their
      # indexes, in a database that cannot join back to this one anyway.
      t.serial :telemetry_id, null: false
      t.citext :slug, null: false
      t.string :name, null: false
      # One of the categorical chart slots (1..8): an app keeps its colour on
      # every chart, in every view, for as long as it exists.
      t.integer :color_slot, null: false, default: 1
      # The app's name in fog, when fog knows it (roster sync).
      t.string :fog_name
      t.string :identity_mode, null: false, default: "pseudonymous"
      # What the agent is told on every flush (the directives half of
      # glass-ingest/1): sampling, profile cadence, log level. Only what a
      # person changed; AgentSettings supplies the defaults.
      t.jsonb :agent_settings, null: false, default: {}
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.timestamps
      t.index :telemetry_id, unique: true
      t.index %i[household_id slug], unique: true
    end

    create_table :ingest_keys, id: :uuid do |t|
      t.references :app, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false, index: { unique: true }
      t.string :prefix, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end
  end
end
