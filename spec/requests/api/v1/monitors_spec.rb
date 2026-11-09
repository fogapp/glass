# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Monitors", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }

  def monitor_with(closed:, open: false)
    rule = MonitorRule.create!(household: household, name: "m#{MonitorRule.count}", kind: "threshold", comparison: "gt",
      threshold: 1, window_seconds: 300, query: { "source" => "transactions" })
    closed.times do |i|
      Incident.create!(household: household, monitor: rule, opened_at: (i + 2).days.ago, closed_at: (i + 1).days.ago)
    end
    current = open ? Incident.create!(household: household, monitor: rule, opened_at: 1.hour.ago) : nil
    [ rule, current ]
  end

  # Incident rows the request loaded into memory.
  def incidents_loaded
    loaded = 0
    callback = ->(*, payload) { loaded += payload[:record_count] if payload[:class_name] == "Incident" }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { yield }
    loaded
  end

  it "lists each monitor's open incident without loading its history" do
    _, current = monitor_with(closed: 2, open: true)
    monitor_with(closed: 1)
    few = incidents_loaded { get "/api/v1/monitors", headers: headers }
    listed = json.to_h { |monitor| [ monitor["name"], monitor["open_incident"]&.fetch("id") ] }
    expect(listed.values).to contain_exactly(current.id, nil)

    monitor_with(closed: 40)
    many = incidents_loaded { get "/api/v1/monitors", headers: headers }
    expect(many).to eq(few)
    expect(few).to eq(1)
  end

  it "shows one monitor's open incident beside its recent history" do
    rule, current = monitor_with(closed: 3, open: true)
    get "/api/v1/monitors/#{rule.id}", headers: headers
    expect(json["open_incident"]["id"]).to eq(current.id)
    expect(json["incidents"].size).to eq(4)
    expect(json["incidents"].first["id"]).to eq(current.id)

    current.update!(closed_at: Time.current)
    get "/api/v1/monitors/#{rule.id}", headers: headers
    expect(json).not_to have_key("open_incident")
    expect(rule.reload.open_incident).to be_nil
  end
end
