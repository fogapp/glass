# typed: strict
# frozen_string_literal: true

module FogBackup
  # Builds one fog-backup/2 artifact into producer staging
  # (fog's docs/backup-contract.md): pg_dump of the primary database with the
  # container's own binary (dump tool matches server by construction — the
  # exact GitLab-2017 failure made impossible), a plain tar of the storage
  # tree, a manifest, and a single outer tar with the manifest first.
  #
  # Every payload is uncompressed (pg_dump -Z0, no tar --zstd): fog keeps
  # artifacts in a deduplicating store that compresses chunks itself, and a
  # whole-stream compressed payload would share nothing night to night.
  #
  # Progress lands on the JobRun row so the /fog job-status endpoint (and the
  # console) can show what a long dump is doing.
  class Producer
    extend T::Sig

    class Error < StandardError; end

    DUMP_TIMEOUT = T.let(3600, Integer)
    TAR_TIMEOUT = T.let(3600, Integer)
    DUMP_PATH = T.let("db/primary.dump", String)
    STORAGE_PATH = T.let("files/storage.tar", String)

    sig { params(job_run: JobRun).void }
    def initialize(job_run:)
      @job_run = job_run
      @workdir = T.let(Staging.backup_root.join("#{job_run.id}.tmp"), Pathname)
    end

    sig { returns(String) }
    def call
      Staging.sweep_stale!
      FileUtils.rm_rf(@workdir)
      @workdir.join("db").mkpath
      @workdir.join("files").mkpath

      progress("dumping primary database")
      dump_primary

      progress("archiving file state")
      archive_storage

      progress("writing manifest")
      manifest = Manifest.build(components: components)
      @workdir.join("manifest.json").write(JSON.pretty_generate(manifest))

      progress("assembling artifact")
      artifact = assemble

      "artifact #{ActiveSupport::NumberHelper.number_to_human_size(artifact[:bytes])}, sha256 #{artifact[:sha256].first(12)}"
    ensure
      FileUtils.rm_rf(@workdir)
    end

    private

    sig { params(message: String).void }
    def progress(message)
      @job_run.update!(message: message)
    end

    sig { void }
    def dump_primary
      argv = [
        "pg_dump", "-Fc", "-Z0", "--no-owner", "--no-privileges", "--no-comments", *Pg.connection_args,
        "-f", @workdir.join(DUMP_PATH).to_s
      ]
      run!(argv, timeout: DUMP_TIMEOUT, env: Pg.env)
    end

    sig { void }
    def archive_storage
      # The storage tree relative to Rails.root, minus fog's own staging —
      # an artifact must never contain staged artifacts.
      run!([
        "tar",
        "--exclude", "storage/fog", "--exclude", "storage/fog/*",
        "-cf", @workdir.join(STORAGE_PATH).to_s,
        "-C", Rails.root.to_s, "storage"
      ], timeout: TAR_TIMEOUT)
    end

    sig { returns(T::Array[Manifest::Component]) }
    def components
      [
        component("primary", DUMP_PATH, "db"),
        component("storage", STORAGE_PATH, "files")
      ]
    end

    sig { params(name: String, path: String, kind: String).returns(Manifest::Component) }
    def component(name, path, kind)
      file = @workdir.join(path)
      Manifest::Component.new(
        name: name, path: path, kind: kind,
        bytes: file.size,
        sha256: Digest::SHA256.file(file.to_s).hexdigest
      )
    end

    # The outer tar is uncompressed and lists the manifest first, so it can
    # be consumed as a forward-only stream with the manifest readable before
    # a byte of payload.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def assemble
      tmp_artifact = @workdir.join("artifact.tar")
      run!([
        "tar", "-cf", tmp_artifact.to_s, "-C", @workdir.to_s,
        "manifest.json", DUMP_PATH, STORAGE_PATH
      ], timeout: TAR_TIMEOUT)

      final_dir = Staging.job_dir(@job_run.id)
      FileUtils.rm_rf(final_dir)
      final_dir.mkpath
      FileUtils.mv(tmp_artifact.to_s, Staging.artifact_path(@job_run.id).to_s)

      info = {
        bytes: Staging.artifact_path(@job_run.id).size,
        sha256: Digest::SHA256.file(Staging.artifact_path(@job_run.id).to_s).hexdigest,
        created_at: Time.current.utc.iso8601
      }
      Staging.artifact_info_path(@job_run.id).write(JSON.generate(info))
      info
    end

    sig { params(argv: T::Array[String], timeout: Integer, env: T::Hash[String, String]).void }
    def run!(argv, timeout:, env: {})
      Tool.run!(argv, timeout: timeout, error: Error, env: env, limit: 500)
    end
  end
end
