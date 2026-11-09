# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Instance settings: where alerts go, how long each signal is kept, how
    # much disk telemetry may use. Admin-only.
    class AppSettingsController < BaseController
      before_action :require_admin!

      sig { void }
      def show
        render json: SettingsSerializer.settings_json(AppSetting.current)
      end

      sig { void }
      def update
        setting = AppSetting.current
        setting.assign_attributes(params.permit(:ntfy_url, :ntfy_topic, :disk_budget_mb, :fog_url, :fog_sync_enabled))
        setting.fog_token = params[:fog_token].to_s if params[:fog_token].present?
        setting.fog_token = nil if bool_param(:clear_fog_token)
        # Blank means "leave it": the token is never sent back, so the form
        # cannot round-trip it. Clearing is explicit.
        setting.ntfy_token = params[:ntfy_token].to_s if params[:ntfy_token].present?
        setting.ntfy_token = nil if bool_param(:clear_ntfy_token)
        retention = params[:retention_days]
        if retention.respond_to?(:to_unsafe_h)
          setting.retention_days = retention.to_unsafe_h.transform_values { |days| days.to_s.to_i }
        end
        # Settings › Fog's "Follow again" sends the list without that name.
        setting.fog_ignored_apps = Array(params[:fog_ignored_apps]).map(&:to_s) if params.key?(:fog_ignored_apps)
        setting.save!
        # A name taken off the list comes back now, not a minute from now.
        FogSyncJob.perform_later if setting.saved_change_to_fog_ignored_apps?
        render json: SettingsSerializer.settings_json(setting)
      end

      # Settings › Fog's Test: one read tool, which also proves the token.
      sig { void }
      def test_fog
        setting = AppSetting.current
        ok = render_connection_test(tested: setting, prefix: "fog_") do
          client = Fog::McpClient.for(setting)
          client ? client.test_connection : [ false, "Enter fog's URL and an MCP token first" ]
        end
        FogSyncJob.perform_later if ok
      end

      sig { void }
      def test_ntfy
        setting = AppSetting.current
        render_connection_test(tested: setting) do
          client = NtfyClient.for(setting)
          client ? client.test_connection : [ false, "Enter an ntfy server first" ]
        end
      end
    end
  end
end
