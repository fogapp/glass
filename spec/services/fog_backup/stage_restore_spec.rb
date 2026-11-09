# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe FogBackup::StageRestore do
  let(:dir) { Pathname.new(Dir.mktmpdir) }

  after do
    FileUtils.rm_rf(dir)
    FileUtils.rm_rf(FogBackup::Staging.root)
  end

  def good_artifact
    payload = "dump bytes"
    manifest = {
      format: "fog-backup/2", app: "glass",
      created_at: Time.current.utc.iso8601,
      produced_by: { git_sha: "abc123", schema_version: FogBackup::Manifest.code_schema_version.to_s },
      pg: { server_major: 18, extensions: {} },
      components: [ { name: "primary", path: "db/primary.dump", kind: "db",
                      bytes: payload.bytesize, sha256: Digest::SHA256.hexdigest(payload) } ],
      external: [], excluded: %w[cache queue],
      identity: { host: nil, webauthn_rp_id: nil }, secrets_fingerprint: {}
    }
    dir.join("db").mkpath
    dir.join("manifest.json").write(JSON.generate(manifest))
    dir.join("db/primary.dump").write(payload)
    system("tar", "-cf", dir.join("artifact.tar").to_s, "-C", dir.to_s, "manifest.json", "db/primary.dump", exception: true)
    dir.join("artifact.tar")
  end

  def upload(path)
    tempfile = Tempfile.new("artifact")
    tempfile.binmode
    tempfile.write(File.binread(path))
    tempfile.flush
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: "artifact.tar", type: "application/x-tar")
  end

  def stage(upload)
    described_class.call(upload: upload, confirm_identity: false, staged_by: "spec", summary: "Armed by the spec")
  end

  it "stages an uploaded artifact, arms it and says so" do
    preflight = stage(upload(good_artifact))

    expect(preflight.ok?).to be(true)
    expect(FogBackup::Staging.pending_artifact).to exist
    expect(FogBackup::Staging.armed?).to be(true)
    expect(ActivityEntry.find_by(event: "backup.restore.armed").summary).to eq("Armed by the spec")
  end

  it "preflights an artifact already at the staging path" do
    FogBackup::Staging.restore_root.mkpath
    FileUtils.cp(good_artifact, FogBackup::Staging.pending_artifact)

    expect(stage(nil).ok?).to be(true)
    expect(FogBackup::Staging.armed?).to be(true)
  end

  it "disarms and removes an artifact that fails preflight" do
    dir.mkpath
    dir.join("junk.tar").write("not a tar")

    preflight = stage(upload(dir.join("junk.tar")))

    expect(preflight.ok?).to be(false)
    expect(preflight.errors).to be_present
    expect(FogBackup::Staging.pending_artifact).not_to exist
    expect(FogBackup::Staging.armed?).to be(false)
    expect(ActivityEntry.where(event: "backup.restore.armed")).not_to exist
  end
end
