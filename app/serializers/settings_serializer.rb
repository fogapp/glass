# typed: strict
# frozen_string_literal: true

module SettingsSerializer
  extend T::Sig

  sig { params(setting: AppSetting).returns(T::Hash[Symbol, T.untyped]) }
  def self.settings_json(setting)
    {
      ntfy_url: setting.ntfy_url, ntfy_topic: setting.ntfy_topic,
      # Whether a token is stored, never the token.
      ntfy_token_set: setting.ntfy_token.present?,
      last_tested_at: setting.last_tested_at, last_test_ok: setting.last_test_ok,
      last_test_message: setting.last_test_message,
      disk_budget_mb: setting.disk_budget_mb,
      fog: {
        url: setting.fog_url, token_set: setting.fog_token.present?, sync_enabled: setting.fog_sync_enabled,
        last_synced_at: setting.fog_last_synced_at, last_error: setting.fog_last_error,
        ignored_apps: setting.fog_ignored_apps,
        last_tested_at: setting.fog_last_tested_at, last_test_ok: setting.fog_last_test_ok, last_test_message: setting.fog_last_test_message
      },
      retention: Telemetry::Tables::ALL.map { |table|
        { table: table.name, label: table.label, days: setting.retention_for(table), default_days: table.retention_days,
          max_days: table.max_retention_days, overridden: setting.retention_days.key?(table.name) }
      }
    }
  end
end
