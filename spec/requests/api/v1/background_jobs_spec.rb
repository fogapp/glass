# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Background jobs", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:guest) { create_user(household: household, role: "guest") }
  let(:definition) { ManagedJobs.find(MaintainPartitionsJob::JOB_KEY) }

  it_behaves_like "a signed-in endpoint", :get, "/api/v1/background_jobs"
  it_behaves_like "a signed-in endpoint", :post, "/api/v1/background_jobs/#{MaintainPartitionsJob::JOB_KEY}/run"

  it "lists every managed job with its recent runs" do
    JobRun.create!(job_key: definition.key, status: "succeeded", trigger: "system", message: "ok")

    get "/api/v1/background_jobs", headers: auth_headers(guest)
    expect(response).to have_http_status(:ok)
    expect(json.map { |job| job["key"] }).to eq(ManagedJobs::ALL.map(&:key))
    job = json.find { |row| row["key"] == definition.key }
    expect(job).to include("label" => definition.label, "description" => definition.description)
    expect(job["runs"]).to include(a_hash_including("job_key" => definition.key, "status" => "succeeded", "trigger" => "system", "message" => "ok"))
  end

  it "runs a job once, answers 409 while it runs, and 404 for a job it does not have" do
    expect {
      post "/api/v1/background_jobs/#{definition.key}/run", headers: auth_headers(admin)
    }.to have_enqueued_job(MaintainPartitionsJob)
    expect(response).to have_http_status(:accepted)
    expect(json).to include("job_key" => definition.key, "trigger" => "manual")
    expect(JobRun.find(json["id"]).household_id).to eq(household.id)

    post "/api/v1/background_jobs/#{definition.key}/run", headers: auth_headers(admin)
    expect(response).to have_http_status(:conflict)
    expect(json["errors"]).to eq([ "That job is already running" ])

    post "/api/v1/background_jobs/nope/run", headers: auth_headers(admin)
    expect(response).to have_http_status(:not_found)
  end

  it "refuses a guest" do
    expect { post "/api/v1/background_jobs/#{definition.key}/run", headers: auth_headers(guest) }.not_to change(JobRun, :count)
    expect(response).to have_http_status(:forbidden)
  end
end
