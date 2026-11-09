# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /ingest/v1/batch", type: :request do
  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household) }
  let(:key) { ingest_key_for(reporting_app) }
  let(:body) { batch_body([ { t: "marker", ts: Time.now.to_f, title: "hi" } ]) }

  def post_batch(text, token: key.token, headers: {})
    post "/ingest/v1/batch", params: text, headers: bearer(token).merge("Content-Type" => "application/x-ndjson").merge(headers)
  end

  it "accepts a gzipped batch and answers the app's directives" do
    post_batch(Zlib.gzip(body), headers: { "Content-Encoding" => "gzip" })
    expect(response).to have_http_status(:accepted)
    expect(json).to include("accepted" => 1, "skipped" => 0)
    expect(json["directives"]).to include("trace_sample_rate" => 0.1, "identity" => "pseudonymous", "profiling" => true)
    expect(Telemetry::Marker.where(app_id: reporting_app.telemetry_id)).to exist
  end

  it "refuses an unknown, revoked or console credential" do
    post_batch(body, token: "glass_ing_" + "0" * 48)
    expect(response).to have_http_status(:unauthorized)

    key.record.revoke!
    post_batch(body)
    expect(response).to have_http_status(:unauthorized)

    user = create_user(household: household)
    post_batch(body, token: ApiSession.generate!(user: user, device: "x").token)
    expect(response).to have_http_status(:unauthorized)
  end

  it "answers 400 for a body it cannot read and 413 for one too large" do
    post_batch("{", headers: {})
    expect(response).to have_http_status(:bad_request)

    stub_const("Ingest::Body::MAX_WIRE_BYTES", 64)
    post_batch(body)
    expect(response).to have_http_status(:content_too_large)
  end

  it "rate limits with Retry-After" do
    stub_const("Ingest::RateLimiter::MAX_BATCHES", 2)
    2.times { post_batch(body) }
    post_batch(body)
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"].to_i).to be_between(1, 60)
  end
end
