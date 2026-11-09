# typed: strict
# frozen_string_literal: true

# JSON shapes for the fog-backup/2 machine surface (fog's docs/backup-contract.md).
# The consumer is fog's Go client, not the console — field names are the
# contract's, snake_case, and stable.
module FogSerializer
  extend T::Sig

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def self.descriptor_json
    {
      contract: FogBackup::Manifest::FORMAT,
      app: FogBackup::Manifest::APP,
      version: {
        git_sha: GlassVersion.sha,
        schema_version: FogBackup::Manifest.code_schema_version.to_s
      },
      pg: FogBackup::Manifest.pg_info.except(:dump_tool),
      components: [
        { name: "primary", kind: "db" },
        { name: "storage", kind: "files" }
      ],
      external: [],
      fresh: !User.exists?,
      last_restore: FogBackup::Staging.receipt&.slice("restored_at", "artifact_created_at", "artifact_git_sha"),
      estimated_bytes: estimated_bytes
    }
  end

  sig { params(run: JobRun).returns(T::Hash[Symbol, T.untyped]) }
  def self.job_json(run)
    status = run.status_enum
    case status
    when JobRun::Status::Queued, JobRun::Status::Running
      { status: "running", progress: run.message }.compact
    when JobRun::Status::Failed
      { status: "failed", error: run.error.presence || "producer job failed" }
    when JobRun::Status::Succeeded
      info = FogBackup::Staging.artifact_info(run.id)
      if info.nil?
        # Succeeded but the staged artifact is gone (swept, or already
        # collected and deleted) — for the contract that's a failure: there
        # is nothing to download.
        { status: "failed", error: "artifact is no longer staged" }
      else
        { status: "completed", artifact: { bytes: info["bytes"].to_i, sha256: info["sha256"].to_s } }
      end
    else
      T.absurd(status)
    end
  end

  sig { params(result: FogBackup::Preflight::Result).returns(T::Hash[Symbol, T.untyped]) }
  def self.preflight_json(result)
    {
      ok: result.ok?,
      errors: result.errors,
      warnings: result.warnings,
      artifact: result.manifest&.raw&.slice("app", "created_at", "produced_by", "identity")
    }
  end

  # Cheap, honest-enough sizing for fog's dashboard: the primary database
  # plus the storage tree. Media is external and reported in the manifest's
  # external section instead.
  sig { returns(Integer) }
  def self.estimated_bytes
    db = ActiveRecord::Base.connection.select_value("SELECT pg_database_size(current_database())").to_i
    storage = Rails.root.join("storage").glob("**/*").sum { |p| p.file? ? p.size : 0 }
    db + storage
  end
end
