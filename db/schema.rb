# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_08_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"

  create_table "activity_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "event", null: false
    t.uuid "household_id"
    t.jsonb "payload", default: {}, null: false
    t.string "severity", default: "info", null: false
    t.string "source", null: false
    t.uuid "subject_id"
    t.string "subject_type"
    t.string "summary", null: false
    t.uuid "trace_id"
    t.index ["created_at"], name: "index_activity_entries_on_created_at"
    t.index ["household_id", "created_at"], name: "index_activity_entries_on_household_id_and_created_at"
    t.index ["severity", "created_at"], name: "index_activity_entries_on_severity_and_created_at"
    t.index ["subject_type", "subject_id"], name: "index_activity_entries_on_subject"
    t.index ["trace_id"], name: "index_activity_entries_on_trace_id"
  end

  create_table "api_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device"
    t.datetime "expires_at"
    t.string "handoff_digest"
    t.datetime "handoff_expires_at"
    t.datetime "last_used_at"
    t.string "oidc_sid"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.string "token_digest", null: false
    t.index ["handoff_digest"], name: "index_api_sessions_on_handoff_digest", unique: true
    t.index ["oidc_sid"], name: "index_api_sessions_on_oidc_sid"
    t.index ["token_digest"], name: "index_api_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_sessions_on_user_id"
  end

  create_table "api_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "prefix", null: false
    t.string "scope", default: "full", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "app_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "disk_budget_mb", default: 6144, null: false
    t.datetime "fog_attested_at"
    t.jsonb "fog_ignored_apps", default: [], null: false
    t.string "fog_last_error"
    t.datetime "fog_last_synced_at"
    t.string "fog_last_test_message"
    t.boolean "fog_last_test_ok"
    t.datetime "fog_last_tested_at"
    t.boolean "fog_sync_enabled", default: true, null: false
    t.text "fog_token"
    t.string "fog_url"
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.text "ntfy_token"
    t.string "ntfy_topic", default: "glass", null: false
    t.string "ntfy_url"
    t.jsonb "retention_days", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index "(true)", name: "index_app_settings_singleton", unique: true
  end

  create_table "apps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "agent_settings", default: {}, null: false
    t.integer "color_slot", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "first_seen_at"
    t.string "fog_name"
    t.jsonb "fog_state", default: {}, null: false
    t.uuid "household_id", null: false
    t.string "identity_mode", default: "pseudonymous", null: false
    t.datetime "last_seen_at"
    t.string "link_template"
    t.string "name", null: false
    t.citext "slug", null: false
    t.serial "telemetry_id", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "slug"], name: "index_apps_on_household_id_and_slug", unique: true
    t.index ["household_id"], name: "index_apps_on_household_id"
    t.index ["telemetry_id"], name: "index_apps_on_telemetry_id", unique: true
  end

  create_table "dashboards", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "household_id", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.jsonb "widgets", default: [], null: false
    t.index ["household_id"], name: "index_dashboards_on_household_id"
  end

  create_table "fog_integrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "api_token_id"
    t.string "consumer", null: false
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.uuid "ingest_key_id"
    t.datetime "updated_at", null: false
    t.index ["api_token_id"], name: "index_fog_integrations_on_api_token_id"
    t.index ["household_id"], name: "index_fog_integrations_on_household_id"
    t.index ["ingest_key_id"], name: "index_fog_integrations_on_ingest_key_id"
  end

  create_table "households", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "identities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "issuer", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["issuer", "subject"], name: "index_identities_on_issuer_and_subject", unique: true
    t.index ["subject"], name: "index_identities_on_subject"
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "incidents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "app_slug"
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.uuid "monitor_id", null: false
    t.datetime "notified_at"
    t.datetime "opened_at", null: false
    t.float "peak_value"
    t.datetime "updated_at", null: false
    t.index ["closed_at"], name: "index_incidents_on_closed_at", where: "(closed_at IS NULL)"
    t.index ["household_id", "opened_at"], name: "index_incidents_on_household_id_and_opened_at"
    t.index ["household_id"], name: "index_incidents_on_household_id"
    t.index ["monitor_id"], name: "index_incidents_on_monitor_id"
  end

  create_table "ingest_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "app_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "prefix", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_ingest_keys_on_app_id"
    t.index ["token_digest"], name: "index_ingest_keys_on_token_digest", unique: true
  end

  create_table "invite_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.datetime "expires_at", null: false
    t.uuid "household_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.index ["code"], name: "index_invite_codes_on_code", unique: true
    t.index ["created_by_id"], name: "index_invite_codes_on_created_by_id"
    t.index ["household_id"], name: "index_invite_codes_on_household_id"
  end

  create_table "job_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "finished_at"
    t.uuid "household_id"
    t.string "job_key", null: false
    t.string "message"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.string "trigger", default: "system", null: false
    t.datetime "updated_at", null: false
    t.index ["finished_at"], name: "index_job_runs_on_finished_at", where: "(finished_at IS NOT NULL)"
    t.index ["household_id", "job_key", "created_at"], name: "index_job_runs_on_household_id_and_job_key_and_created_at"
    t.index ["job_key", "created_at"], name: "index_job_runs_on_job_key_and_created_at"
  end

  create_table "monitors", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "comparison", default: "gt", null: false
    t.datetime "created_at", null: false
    t.integer "deploy_grace_seconds", default: 0, null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.integer "for_seconds", default: 0, null: false
    t.uuid "household_id", null: false
    t.string "kind", default: "threshold", null: false
    t.text "last_error"
    t.datetime "last_evaluated_at"
    t.float "last_value"
    t.string "name", null: false
    t.boolean "notify", default: true, null: false
    t.datetime "pending_since"
    t.jsonb "query", default: {}, null: false
    t.string "state", default: "no_data", null: false
    t.datetime "state_since"
    t.float "threshold", default: 0.0, null: false
    t.datetime "updated_at", null: false
    t.integer "window_seconds", default: 300, null: false
    t.index ["household_id"], name: "index_monitors_on_household_id"
  end

  create_table "triage_dismissals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "finding_id", null: false
    t.uuid "household_id", null: false
    t.string "mode", null: false
    t.float "score", null: false
    t.string "severity", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["household_id", "finding_id"], name: "index_triage_dismissals_on_household_id_and_finding_id", unique: true
    t.index ["household_id"], name: "index_triage_dismissals_on_household_id"
    t.index ["user_id"], name: "index_triage_dismissals_on_user_id"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.citext "email", null: false
    t.uuid "household_id", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["household_id"], name: "index_users_on_household_id"
  end

  create_table "webauthn_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.datetime "last_used_at"
    t.string "nickname"
    t.text "public_key", null: false
    t.bigint "sign_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
    t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
  end

  add_foreign_key "activity_entries", "households", on_delete: :cascade
  add_foreign_key "api_sessions", "users", on_delete: :cascade
  add_foreign_key "api_tokens", "users", on_delete: :cascade
  add_foreign_key "apps", "households", on_delete: :cascade
  add_foreign_key "dashboards", "households", on_delete: :cascade
  add_foreign_key "fog_integrations", "api_tokens", on_delete: :nullify
  add_foreign_key "fog_integrations", "households", on_delete: :cascade
  add_foreign_key "fog_integrations", "ingest_keys", on_delete: :nullify
  add_foreign_key "identities", "users", on_delete: :cascade
  add_foreign_key "incidents", "households", on_delete: :cascade
  add_foreign_key "incidents", "monitors", on_delete: :cascade
  add_foreign_key "ingest_keys", "apps", on_delete: :cascade
  add_foreign_key "invite_codes", "households", on_delete: :cascade
  add_foreign_key "invite_codes", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "job_runs", "households", on_delete: :cascade
  add_foreign_key "monitors", "households", on_delete: :cascade
  add_foreign_key "triage_dismissals", "households", on_delete: :cascade
  add_foreign_key "triage_dismissals", "users", on_delete: :nullify
  add_foreign_key "users", "households", on_delete: :cascade
  add_foreign_key "webauthn_credentials", "users", on_delete: :cascade
end
