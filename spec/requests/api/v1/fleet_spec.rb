# typed: false
# frozen_string_literal: true

require "rails_helper"

# The fleet page and the console's status line: every reporting process,
# and the figures the header shows.
RSpec.describe "Fleet and status", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:theirs) { create_app(household: create_household(name: "Other"), slug: "theirs") }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/fleet"
  it_behaves_like "a signed-in endpoint", :get, "/api/v1/status"

  before do
    write_batch(hook, [ wire_txn(at: Time.now - 10) ], kind: "web", pid: 1)
    write_batch(hook, [ wire_txn(at: Time.now - 10) ], kind: "job", pid: 2)
    write_batch(theirs, [ wire_txn(at: Time.now - 10), wire_txn(at: Time.now - 10) ], kind: "web", pid: 3)
  end

  it "lists the household's processes, never another household's" do
    get "/api/v1/fleet", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json.map { |process| [ process["app"], process["kind"], process["pid"] ] }).to contain_exactly([ "hook", "web", 1 ], [ "hook", "job", 2 ])
    expect(json.first).to include("host" => "spec-host", "release" => "abc1234", "live" => true, "batches" => 1, "records" => 1)
    expect(json.first.keys).to include("runtime", "started_at", "first_seen_at", "last_seen_at", "dropped")
  end

  it "summarises the household's apps, processes and throughput" do
    create_app(household: household, slug: "quiet")

    get "/api/v1/status", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json).to include("apps" => { "total" => 2, "reporting" => 1 }, "processes" => { "live" => 2, "total" => 2 })
    expect(json["throughput"]).to be_within(0.001).of(2 / 60.0)
    expect(json["storage"]).to include("budget_bytes" => AppSetting.current.disk_budget_mb.megabytes)
    expect(json["storage"]["used_bytes"]).to be_a(Integer)
    expect(json.keys).to include("now", "last_seen_at", "release")
  end
end
