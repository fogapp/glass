# typed: strict
# frozen_string_literal: true

# Every minute, once fog is connected in Settings › Fog: the roster, the
# container vitals, health and deploys (Fog::Sync).
class FogSyncJob < ApplicationJob
  extend T::Sig
  include ManagedJob

  JOB_KEY = "fog_sync"
  DESCRIPTION = "Read fog's app roster, container vitals, health and deploys through its MCP tools."

  queue_as :fog
  limits_concurrency key: JOB_KEY, duration: 5.minutes

  sig { override.returns(T.nilable(String)) }
  def run_job
    setting = AppSetting.current
    client = Fog::McpClient.for(setting)
    return "fog is not connected" if client.nil? || !setting.fog_sync_enabled

    household = Household.instance
    return "no household yet" if household.nil?

    begin
      result = Fog::Sync.call(household: household, client: client)
      setting.update_columns(fog_last_synced_at: Time.current, fog_last_error: nil) # rubocop:disable Rails/SkipsModelValidations
      "#{result.apps} apps (#{result.created} new), #{result.points} vitals, #{result.markers} markers"
    rescue UpstreamHttpClient::Error => e
      setting.update_columns(fog_last_error: e.message.truncate(250)) # rubocop:disable Rails/SkipsModelValidations
      Activity.record(source: "fog", event: "fog.sync_failed", severity: Activity::Severity::Warn, summary: "fog sync failed: #{e.message}")
      "failed: #{e.message.truncate(120)}"
    end
  end
end
