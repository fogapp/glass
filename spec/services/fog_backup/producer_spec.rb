# typed: false
# frozen_string_literal: true

require "rails_helper"

# Real pg_dump + real tar: the artifact this produces is the artifact fog
# downloads, so the round trip through Preflight is the contract's own test.
RSpec.describe FogBackup::Producer do
  after { FileUtils.rm_rf(FogBackup::Staging.root) }

  it "produces a verifiable artifact that passes preflight" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")

    message = described_class.new(job_run: run).call

    expect(message).to include("artifact")

    path = FogBackup::Staging.artifact_path(run.id)
    info = FogBackup::Staging.artifact_info(run.id)
    expect(path).to exist
    # The producer's claim must be independently verifiable — it's what fog
    # checks the download against.
    expect(path.size).to eq(info["bytes"])
    expect(Digest::SHA256.file(path.to_s).hexdigest).to eq(info["sha256"])

    result = FogBackup::Preflight.check(artifact_path: path)
    expect(result.errors).to eq([])
    expect(result.manifest.app).to eq("glass")
    expect(result.manifest.schema_version).to eq(FogBackup::Manifest.code_schema_version)
    expect(result.manifest.components.map { |c| c["name"] }).to contain_exactly("primary", "storage")
  end

  # fog-backup/2: payloads uncompressed so fog's store can deduplicate them.
  it "produces a fog-backup/2 artifact with uncompressed payloads" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")
    calls = []
    allow(ToolRunner).to receive(:run).and_wrap_original do |original, argv, **opts|
      calls << argv
      original.call(argv, **opts)
    end

    described_class.new(job_run: run).call

    dump = calls.find { |argv| argv.first == "pg_dump" }
    expect(dump).to include("-Fc", "-Z0", "--no-owner", "--no-privileges", "--no-comments")
    archive = calls.find { |argv| argv.first == "tar" && argv.include?("storage") }
    expect(archive).not_to include("--zstd")

    result = FogBackup::Preflight.check(artifact_path: FogBackup::Staging.artifact_path(run.id))
    expect(result.errors).to eq([])
    expect(result.manifest.format).to eq("fog-backup/2")
    paths = result.manifest.components.to_h { |c| [ c["name"], c["path"] ] }
    expect(paths).to eq("primary" => "db/primary.dump", "storage" => "files/storage.tar")
  end

  it "cleans its workdir on failure and leaves nothing staged" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")
    allow(ToolRunner).to receive(:run)
      .and_return(ToolRunner::Result.new(status: 1, stdout: "", stderr: "pg_dump: error"))

    expect { described_class.new(job_run: run).call }.to raise_error(FogBackup::Producer::Error, /pg_dump/)
    expect(FogBackup::Staging.job_dir(run.id)).not_to exist
    expect(FogBackup::Staging.backup_root.join("#{run.id}.tmp")).not_to exist
  end
end
