# typed: false
# frozen_string_literal: true

require "rails_helper"

# Restorers accept every version they know (fog's docs/backup-contract.md):
# a fog-backup/1 artifact (zstd file tars) restores exactly as a
# fog-backup/2 one (plain file tars), each component read from the path its
# manifest names. pg_restore itself is stubbed — it would clobber the test
# database out from under the spec's transaction — but tar runs for real.
RSpec.describe FogBackup::Restorer do
  let(:dir) { Pathname.new(Dir.mktmpdir) }
  let(:marker_dir) { "restorer-spec-#{SecureRandom.hex(4)}" }
  let(:restored_file) { Rails.root.join("storage", marker_dir, "hello.txt") }
  let(:calls) { [] }

  before do
    allow(ToolRunner).to receive(:run).and_wrap_original do |original, argv, **opts|
      calls << argv
      if argv.first == "pg_restore"
        ToolRunner::Result.new(status: 0, stdout: "", stderr: "")
      else
        original.call(argv, **opts)
      end
    end
    allow(ActiveRecord::Base.connection).to receive(:reconnect!)
  end

  after do
    FileUtils.rm_rf(dir)
    FileUtils.rm_rf(FogBackup::Staging.root)
    FileUtils.rm_rf(Rails.root.join("storage", marker_dir))
  end

  def component(name, path, kind)
    file = dir.join("payload", path)
    { name: name, path: path, kind: kind, bytes: file.size, sha256: Digest::SHA256.file(file.to_s).hexdigest }
  end

  def stage_artifact(format:, storage_path:)
    payload = dir.join("payload")
    payload.join("db").mkpath
    payload.join("files").mkpath
    payload.join("db/primary.dump").write("dump bytes")

    tree = dir.join("tree")
    tree.join("storage", marker_dir).mkpath
    tree.join("storage", marker_dir, "hello.txt").write("hello from the backup")
    zstd = storage_path.end_with?(".zst") ? [ "--zstd" ] : []
    system("tar", *zstd, "-cf", payload.join(storage_path).to_s, "-C", tree.to_s, "storage", exception: true)

    manifest = {
      format: format, app: "glass",
      created_at: Time.current.utc.iso8601,
      produced_by: { git_sha: "abc123", schema_version: FogBackup::Manifest.code_schema_version.to_s },
      pg: { server_major: 18, extensions: {} },
      components: [ component("primary", "db/primary.dump", "db"), component("storage", storage_path, "files") ],
      external: [], excluded: %w[telemetry cache queue],
      identity: { host: nil, webauthn_rp_id: nil }, secrets_fingerprint: {}
    }
    payload.join("manifest.json").write(JSON.generate(manifest))

    FogBackup::Staging.restore_root.mkpath
    system("tar", "-cf", FogBackup::Staging.pending_artifact.to_s, "-C", payload.to_s,
      "manifest.json", "db/primary.dump", storage_path, exception: true)
    FogBackup::Staging.arm!(confirm_identity: false, staged_by: "spec")
  end

  def storage_unpack
    calls.find { |argv| argv.first == "tar" && argv.include?("-xf") && argv.any? { |a| a.include?("files/storage") } }
  end

  it "restores a fog-backup/2 artifact (plain tar file component)" do
    stage_artifact(format: "fog-backup/2", storage_path: "files/storage.tar")

    expect(described_class.run_if_armed!).to be(true)

    expect(calls.find { |argv| argv.first == "pg_restore" }.last).to end_with("work/db/primary.dump")
    expect(storage_unpack).not_to include("--zstd")
    expect(storage_unpack).to include(a_string_ending_with("files/storage.tar"))
    expect(restored_file.read).to eq("hello from the backup")
    expect(FogBackup::Staging.armed?).to be(false)
    expect(FogBackup::Staging.receipt).to include("artifact_git_sha" => "abc123")
  end

  it "still restores a fog-backup/1 artifact (zstd tar file component)", skip: (ToolRunner.version("zstd").nil? && "zstd not installed") do
    stage_artifact(format: "fog-backup/1", storage_path: "files/storage.tar.zst")

    expect(described_class.run_if_armed!).to be(true)

    expect(storage_unpack).to include("--zstd")
    expect(storage_unpack).to include(a_string_ending_with("files/storage.tar.zst"))
    expect(restored_file.read).to eq("hello from the backup")
    expect(FogBackup::Staging.armed?).to be(false)
  end

  it "holds the restore lock across the reconnect after pg_restore" do
    stage_artifact(format: "fog-backup/2", storage_path: "files/storage.tar")
    held_after_reconnect = nil
    on_pooled_session = nil
    allow(ActiveRecord::Base.connection).to receive(:reconnect!) do
      # The pooled session is the one reconnect! throws away: the lock must
      # not live there.
      on_pooled_session = ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
      ).to_i
      sibling = FogBackup::Pg.connect
      begin
        got = sibling.exec_params("SELECT pg_try_advisory_lock(hashtext($1))", [ described_class::LOCK_KEY ]).getvalue(0, 0)
        held_after_reconnect = got == "f"
      ensure
        sibling.close
      end
    end

    expect(described_class.run_if_armed!).to be(true)
    expect(held_after_reconnect).to be(true)
    expect(on_pooled_session).to eq(0)
  end

  it "refuses an artifact of an unknown format and stays armed" do
    stage_artifact(format: "fog-backup/3", storage_path: "files/storage.tar")

    expect { described_class.run_if_armed! }.to raise_error(described_class::Error, /fog-backup\/3/)
    expect(calls.map(&:first)).not_to include("pg_restore")
    expect(FogBackup::Staging.armed?).to be(true)
  end

  describe ".unpack_flags" do
    it "picks the tar flags by extension" do
      expect(described_class.unpack_flags(Pathname("files/storage.tar.zst"))).to eq([ "--zstd" ])
      expect(described_class.unpack_flags(Pathname("files/storage.tar"))).to eq([])
      expect { described_class.unpack_flags(Pathname("files/storage.zip")) }.to raise_error(described_class::Error)
    end
  end
end
