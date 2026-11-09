# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Triage", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:now) { Time.now.utc }
  let(:range) { { from: (now - 1.hour).to_i, to: now.to_i } }

  before do
    write_batch(hook, Array.new(5) do |index|
      { t: "txn", ts: (now - (index + 1).minutes).to_f, kind: "request", name: "Wants#create", trace: SecureRandom.hex(16),
        span: SecureRandom.hex(8), dur: 20.0, status: "error", http: 500, error: "Boom" }
    end)
  end

  it "lists findings for a range, even for a guest, and works one up" do
    get "/api/v1/triage", params: range, headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json["baseline_from"]).to be_within(1).of(range[:from] - 1.day.to_i)
    finding = json["findings"].first
    expect(finding).to include("kind" => "failing", "severity" => "critical", "app" => "hook", "work" => "request", "name" => "Wants#create")

    get "/api/v1/triage/#{finding['id']}", params: range, headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json).to include("title" => "hook · Wants#create is failing", "source" => "transactions",
      "filter" => %(app:hook kind:request name:"Wants#create"))
    expect(json["evidence"].map { |evidence| evidence["type"] }).to include("chart", "table", "traces")
    expect(json["evidence"].first["query"]).to include("shape" => "timeseries", "compute" => %w[errors error_rate])
    expect(json["brief"]).to start_with("# hook · Wants#create is failing")
  end

  it "scopes to an app, and 404s a finding that is not one or no longer stands out" do
    get "/api/v1/triage", params: range.merge(app: "nope"), headers: auth_headers(user)
    expect(json["findings"]).to eq([])

    get "/api/v1/triage", params: range.merge(app: "hook status:ok"), headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)

    get "/api/v1/triage/garbage", params: range, headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)

    calm = Triage::Subject.new(kind: Triage::Kind::Regression, app: "hook", work: "request", name: "Wants#create").id
    get "/api/v1/triage/#{calm}", params: range, headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)
    expect(json["errors"].first).to include("no longer stands out")
  end

  describe "dismissing" do
    let(:member) { create_user(household: household) }
    let(:finding_id) do
      get "/api/v1/triage", params: range, headers: auth_headers(member)
      json["findings"].first["id"]
    end

    def listed
      get "/api/v1/triage", params: range, headers: auth_headers(member)
      json
    end

    it "hides a dismissed finding until it is worse than it was, and puts it back on delete" do
      put "/api/v1/triage/#{finding_id}/dismissal", params: range.merge(mode: "dismissed"), headers: auth_headers(member)
      expect(response).to have_http_status(:ok)
      expect(json).to include("mode" => "dismissed", "severity" => "critical", "by" => "Test User")
      expect(json["returns_above"]).to eq(json["score"] + 10)

      expect(listed["findings"]).to eq([])
      expect(listed["hidden"].map { |row| row["id"] }).to eq([ finding_id ])
      expect(listed["hidden"].first["dismissal"]).to include("mode" => "dismissed", "regressed" => false)

      # Dismissed when it was a notice: it is worse now, so it is back, saying so.
      TriageDismissal.find_by!(finding_id: finding_id).update!(score: 20, severity: "notice")
      expect(listed["findings"].first).to include("id" => finding_id)
      expect(listed["findings"].first["dismissal"]).to include("regressed" => true)

      get "/api/v1/triage/#{finding_id}", params: range, headers: auth_headers(member)
      expect(json["dismissal"]).to include("mode" => "dismissed", "regressed" => true)

      delete "/api/v1/triage/#{finding_id}/dismissal", headers: auth_headers(member)
      expect(response).to have_http_status(:no_content)
      expect(listed["findings"].first).to include("id" => finding_id, "dismissal" => nil)
      expect(listed["hidden"]).to eq([])
    end

    it "keeps an ignored finding out however bad it gets" do
      put "/api/v1/triage/#{finding_id}/dismissal", params: range.merge(mode: "ignored"), headers: auth_headers(member)
      TriageDismissal.find_by!(finding_id: finding_id).update!(score: 0, severity: "notice")
      expect(listed["findings"]).to eq([])
      expect(listed["hidden"].first["dismissal"]).to include("mode" => "ignored", "returns_above" => nil)

      # Answering again changes the answer rather than adding one.
      put "/api/v1/triage/#{finding_id}/dismissal", params: range.merge(mode: "dismissed"), headers: auth_headers(member)
      expect(TriageDismissal.where(finding_id: finding_id).pluck(:mode)).to eq([ "dismissed" ])
    end

    it "refuses a guest, a mode it does not know, and a finding that is not there" do
      put "/api/v1/triage/#{finding_id}/dismissal", params: range.merge(mode: "dismissed"), headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)

      put "/api/v1/triage/#{finding_id}/dismissal", params: range.merge(mode: "snoozed"), headers: auth_headers(member)
      expect(response).to have_http_status(:unprocessable_content)

      calm = Triage::Subject.new(kind: Triage::Kind::Regression, app: "hook", work: "request", name: "Wants#create").id
      put "/api/v1/triage/#{calm}/dismissal", params: range.merge(mode: "ignored"), headers: auth_headers(member)
      expect(response).to have_http_status(:not_found)

      delete "/api/v1/triage/#{calm}/dismissal", headers: auth_headers(member)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "answers 422 for a range it cannot read" do
    get "/api/v1/triage", params: { from: range[:to], to: range[:from] }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
    get "/api/v1/triage", headers: auth_headers(user)
    expect(json["errors"].first).to include("“from” is required")
  end
end
