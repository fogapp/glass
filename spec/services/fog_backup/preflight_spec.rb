# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe FogBackup::Preflight do
  let(:dir) { Pathname.new(Dir.mktmpdir) }

  after { FileUtils.rm_rf(dir) }

  def build_artifact(manifest_overrides: {}, corrupt_component: false)
    payload = "dump bytes"
    manifest = {
      format: "fog-backup/2",
      app: "glass",
      created_at: Time.current.utc.iso8601,
      produced_by: { git_sha: "abc123", schema_version: FogBackup::Manifest.code_schema_version.to_s },
      pg: { server_major: 18, extensions: {} },
      components: [
        { name: "primary", path: "db/primary.dump", kind: "db",
          bytes: payload.bytesize, sha256: Digest::SHA256.hexdigest(payload) }
      ],
      external: [], excluded: %w[cache queue],
      identity: { host: nil, webauthn_rp_id: nil },
      secrets_fingerprint: {}
    }.deep_merge(manifest_overrides)

    dir.join("db").mkpath
    dir.join("manifest.json").write(JSON.generate(manifest))
    dir.join("db/primary.dump").write(corrupt_component ? "tampered!!" : payload)
    system("tar", "-cf", dir.join("artifact.tar").to_s, "-C", dir.to_s,
      "manifest.json", "db/primary.dump", exception: true)
    dir.join("artifact.tar")
  end

  it "accepts a well-formed artifact" do
    result = described_class.check(artifact_path: build_artifact)
    expect(result.errors).to eq([])
    expect(result.ok?).to be(true)
  end

  # Restorers accept every version they know (fog's docs/backup-contract.md).
  it "accepts a fog-backup/1 artifact" do
    result = described_class.check(artifact_path: build_artifact(manifest_overrides: { format: "fog-backup/1" }))
    expect(result.errors).to eq([])
    expect(result.manifest.format).to eq("fog-backup/1")
  end

  it "refuses an unknown format" do
    result = described_class.check(artifact_path: build_artifact(manifest_overrides: { format: "fog-backup/3" }))
    expect(result.ok?).to be(false)
    expect(result.errors.join).to include("format \"fog-backup/3\"")
  end

  it "refuses another app's artifact" do
    result = described_class.check(artifact_path: build_artifact(manifest_overrides: { app: "hub" }))
    expect(result.errors.join).to include("app \"hub\"")
  end

  it "refuses an artifact newer than the running code" do
    newer = (FogBackup::Manifest.code_schema_version + 1).to_s
    result = described_class.check(
      artifact_path: build_artifact(manifest_overrides: { produced_by: { schema_version: newer } })
    )
    expect(result.errors.join).to include("newer than this code")
  end

  it "refuses a corrupt component" do
    result = described_class.check(artifact_path: build_artifact(corrupt_component: true))
    expect(result.errors.join).to include("checksum")
  end

  it "refuses when a required extension is missing" do
    result = described_class.check(
      artifact_path: build_artifact(manifest_overrides: { pg: { extensions: { made_up_ext: "1.0" } } })
    )
    expect(result.errors.join).to include("made_up_ext")
  end

  it "refuses when the artifact was written with keys this instance lacks" do
    result = described_class.check(
      artifact_path: build_artifact(
        manifest_overrides: { secrets_fingerprint: { AR_ENCRYPTION_PRIMARY_KEY: "sha256:deadbeef0000" } }
      )
    )
    expect(result.errors.join).to include("unreadable ciphertext")
  end

  # A host change breaks federation identity — proceeding must be a decision.
  describe "identity drift" do
    let(:artifact) do
      build_artifact(manifest_overrides: { identity: { host: "old.example.com" } })
    end

    it "refuses without confirmation" do
      result = described_class.check(artifact_path: artifact)
      expect(result.errors.join).to include("confirm_identity")
    end

    it "proceeds with a warning when confirmed" do
      result = described_class.check(artifact_path: artifact, confirm_identity: true)
      expect(result.errors).to eq([])
      expect(result.warnings.join).to include("confirmed")
    end
  end

  it "reports an unreadable artifact rather than raising" do
    dir.join("junk.tar").write("not a tar at all")
    result = described_class.check(artifact_path: dir.join("junk.tar"))
    expect(result.ok?).to be(false)
  end
end
