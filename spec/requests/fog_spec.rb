# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "fog-backup/2 surface", type: :request do
  include_context "with fog token"

  after { FileUtils.rm_rf(FogBackup::Staging.root) }

  describe "auth" do
    it "rejects a missing bearer" do
      get "/fog/backup"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a wrong bearer" do
      get "/fog/backup", headers: bearer("nope")
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses everything when no token is configured" do
      ENV.delete("FOG_API_TOKEN")
      get "/fog/backup", headers: fog_headers
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /fog/backup (descriptor)" do
    it "describes the instance" do
      get "/fog/backup", headers: fog_headers

      expect(response).to have_http_status(:ok)
      expect(json["contract"]).to eq("fog-backup/2")
      expect(json["app"]).to eq("glass")
      expect(json["fresh"]).to be(true)
      expect(json["components"].map { |c| c["name"] }).to contain_exactly("primary", "storage")
      expect(json["external"]).to eq([])
      expect(json["version"]["schema_version"].to_i).to be > 0
    end

    it "reports fresh: false once a user exists" do
      create_user(household: create_household)
      get "/fog/backup", headers: fog_headers
      expect(json["fresh"]).to be(false)
    end
  end

  describe "POST /fog/backup" do
    it "starts a producer job and 409s while it runs, reporting the same job" do
      post "/fog/backup", headers: fog_headers
      expect(response).to have_http_status(:accepted)
      first_job = json["job"]
      expect(ProduceBackupJob).to have_been_enqueued.with(first_job)

      post "/fog/backup", headers: fog_headers
      expect(response).to have_http_status(:conflict)
      expect(json["job"]).to eq(first_job)
    end
  end

  describe "GET /fog/backup/jobs/:id" do
    it "404s an unknown or garbage id" do
      get "/fog/backup/jobs/not-a-uuid", headers: fog_headers
      expect(response).to have_http_status(:not_found)

      get "/fog/backup/jobs/#{SecureRandom.uuid}", headers: fog_headers
      expect(response).to have_http_status(:not_found)
    end

    it "maps run states onto the contract vocabulary" do
      run = JobRun.create!(job_key: "produce_backup", trigger: "system")
      get "/fog/backup/jobs/#{run.id}", headers: fog_headers
      expect(json["status"]).to eq("running")

      run.update!(status: "failed", error: "pg_dump exited 1")
      get "/fog/backup/jobs/#{run.id}", headers: fog_headers
      expect(json).to eq("status" => "failed", "error" => "pg_dump exited 1")
    end

    it "reports a completed artifact with the producer's claim" do
      run = JobRun.create!(job_key: "produce_backup", trigger: "system", status: "succeeded")
      FogBackup::Staging.job_dir(run.id).mkpath
      FogBackup::Staging.artifact_path(run.id).write("tar bytes")
      FogBackup::Staging.artifact_info_path(run.id).write({ bytes: 9, sha256: "abc" }.to_json)

      get "/fog/backup/jobs/#{run.id}", headers: fog_headers
      expect(json["status"]).to eq("completed")
      expect(json["artifact"]).to eq("bytes" => 9, "sha256" => "abc")
    end

    it "calls a succeeded run with no staged artifact failed — nothing to download" do
      run = JobRun.create!(job_key: "produce_backup", trigger: "system", status: "succeeded")
      get "/fog/backup/jobs/#{run.id}", headers: fog_headers
      expect(json["status"]).to eq("failed")
    end
  end

  describe "artifact download and cleanup" do
    let(:run) do
      JobRun.create!(job_key: "produce_backup", trigger: "system",
        status: "succeeded", finished_at: Time.current).tap do |r|
        FogBackup::Staging.job_dir(r.id).mkpath
        FogBackup::Staging.artifact_path(r.id).write("tar bytes")
        FogBackup::Staging.artifact_info_path(r.id).write({ bytes: 9, sha256: "abc" }.to_json)
      end
    end

    it "streams the artifact with an exact length" do
      get "/fog/backup/jobs/#{run.id}/artifact", headers: fog_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("tar bytes")
      expect(response.content_type).to eq("application/x-tar")
    end

    it "removes staging on DELETE" do
      delete "/fog/backup/jobs/#{run.id}", headers: fog_headers

      expect(response).to have_http_status(:no_content)
      expect(FogBackup::Staging.job_dir(run.id)).not_to exist
    end
  end

  describe "POST /fog/restore" do
    it "refuses when the instance already has data" do
      create_user(household: create_household)
      post "/fog/restore", headers: fog_headers, params: { staged: true }
      expect(response).to have_http_status(:conflict)
    end

    it "requires an artifact or staged flag" do
      post "/fog/restore", headers: fog_headers
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an unreadable staged artifact and disarms" do
      FogBackup::Staging.restore_root.mkpath
      FogBackup::Staging.pending_artifact.write("not a tar")

      post "/fog/restore", headers: fog_headers, params: { staged: true }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"]).to be_present
      expect(FogBackup::Staging.pending_artifact).not_to exist
    end
  end
end
