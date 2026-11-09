# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Flamegraphs", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "guest") }
  let(:hook) { create_app(household: household, slug: "hook") }
  let(:theirs) { create_app(household: create_household(name: "Other"), slug: "theirs") }
  let(:now) { Time.now.utc }

  it_behaves_like "a signed-in endpoint", :post, "/api/v1/profiles/flamegraph"

  def profile(at:, samples:)
    { t: "profile", ts: at.to_f, dur: 60.0, hz: 100, funcs: [ [ "main", "app.rb", 1, "app" ], [ "work", "app/w.rb", 5, "app" ] ],
      stacks: [ [ 0, 1 ] ], samples: [ [ 0, "A#index", "running", samples ] ] }
  end

  def flamegraph(token: nil, **body)
    headers = (token ? bearer(token) : auth_headers(user)).merge("Content-Type" => "application/json")
    post "/api/v1/profiles/flamegraph", params: { from: (now - 1.hour).to_f, to: now.to_f }.merge(body).to_json, headers: headers
  end

  before do
    write_batch(hook, [ profile(at: now - 10.minutes, samples: 10), profile(at: now - 2.hours, samples: 30) ])
    write_batch(theirs, [ profile(at: now - 10.minutes, samples: 500) ])
  end

  it "merges the household's samples in range — a guest and a read-only token may ask" do
    flamegraph
    expect(response).to have_http_status(:ok)
    expect(json).to include("total_ms" => 100.0, "baseline_total_ms" => nil, "diff" => false)
    expect(json["functions"].map { |function| function["name"] }).to include("main", "work")

    read_token = ApiToken.generate(user: user, name: "read", scope: ApiToken::Scope::Read).token
    flamegraph(token: read_token, filter: "app:theirs")
    expect(response).to have_http_status(:ok)
    expect(json["total_ms"]).to eq(0.0)
  end

  it "diffs against a baseline range that keeps the filter" do
    flamegraph(filter: "app:hook", baseline: { from: (now - 3.hours).to_f, to: (now - 1.hour).to_f })
    expect(json).to include("total_ms" => 100.0, "baseline_total_ms" => 300.0, "diff" => true)
  end

  it "422s a range it cannot read" do
    flamegraph(to: "whenever")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("“to”")
  end
end
