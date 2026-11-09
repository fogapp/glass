# frozen_string_literal: true

# The platform tables every house app carries (hook's auth and operations
# stack, whole): one household, its users and their credentials, the
# activity trail, managed job runs, and the instance settings singleton.
class CreatePlatform < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"
    enable_extension "pg_trgm"
    enable_extension "pgcrypto"

    create_table :households, id: :uuid do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :users, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.citext :email, null: false, index: { unique: true }
      t.string :name, null: false
      t.string :password_digest, null: false
      t.string :role, null: false, default: "member"
      t.timestamps
    end

    create_table :api_sessions, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :token, null: false, index: { unique: true }
      t.string :device
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :api_tokens, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false, index: { unique: true }
      t.string :prefix, null: false
      t.string :scope, null: false, default: "full"
      t.datetime :expires_at
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :webauthn_credentials, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :external_id, null: false, index: { unique: true }
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.string :nickname
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :invite_codes, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :code, null: false, index: { unique: true }
      t.string :role, null: false, default: "member"
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end

    create_table :activity_entries, id: :uuid do |t|
      t.references :household, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.string :source, null: false
      t.string :event, null: false
      t.string :severity, null: false, default: "info"
      t.string :summary, null: false
      t.string :subject_type
      t.uuid :subject_id
      t.jsonb :payload, null: false, default: {}
      t.integer :duration_ms
      t.uuid :trace_id
      t.datetime :created_at, null: false
      t.index :created_at
      t.index %i[household_id created_at]
      t.index %i[severity created_at]
      t.index %i[subject_type subject_id], name: "index_activity_entries_on_subject"
      t.index :trace_id
    end

    create_table :job_runs, id: :uuid do |t|
      t.references :household, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
      t.string :job_key, null: false
      t.string :status, null: false, default: "queued"
      t.string :trigger, null: false, default: "system"
      t.string :message
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index :finished_at, where: "(finished_at IS NOT NULL)"
      t.index %i[household_id job_key created_at]
      t.index %i[job_key created_at]
    end

    # One row for the instance (unique index on `true`): where alerts go and
    # how much disk telemetry may use. Retention windows live here too, as
    # overrides of Telemetry::Tables' defaults — only what a person changed.
    create_table :app_settings, id: :uuid do |t|
      t.string :ntfy_url
      t.string :ntfy_topic, null: false, default: "glass"
      t.text :ntfy_token
      t.datetime :last_tested_at
      t.boolean :last_test_ok
      t.string :last_test_message
      t.integer :disk_budget_mb, null: false, default: 6144
      t.jsonb :retention_days, null: false, default: {}
      t.timestamps
      t.index "(true)", unique: true, name: "index_app_settings_singleton"
    end
  end
end
