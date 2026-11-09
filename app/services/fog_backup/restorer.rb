# typed: strict
# frozen_string_literal: true

module FogBackup
  # Restore-on-boot (fog's docs/backup-contract.md): consume the staged, armed
  # artifact before the app serves traffic. Invoked from fog:release (fog's
  # release phase — single instance, no traffic) and from the docker
  # entrypoint (a container restart after the setup wizard armed a restore).
  #
  # Exactly one process restores: everything runs under a session-level
  # Postgres advisory lock, so when web, worker, and streamer containers all
  # boot through the entrypoint at once, one does the work and the others
  # find the marker gone when the lock frees.
  #
  # pg_restore runs as the app's own database role, so every restored object
  # is owned correctly — no post-restore REASSIGN OWNED fix-up.
  #
  # Restores every format it has ever produced (Manifest::ACCEPTED_FORMATS):
  # each component is read from the path its manifest entry names and file
  # components are unpacked by extension — fog-backup/1's .tar.zst with
  # zstd, fog-backup/2's .tar as is. pg_restore reads a custom-format dump
  # the same whether or not it was compressed.
  class Restorer
    extend T::Sig

    class Error < StandardError; end

    RESTORE_TIMEOUT = T.let(3600 * 2, Integer)
    LOCK_KEY = T.let("fog_backup_restore", String)

    # Runs the restore when one is staged and armed. Returns true when this
    # process performed a restore.
    sig { returns(T::Boolean) }
    def self.run_if_armed!
      return false unless Staging.armed?

      new.call
    end

    # The lock lives on a connection of its own: restore_primary reconnects
    # Active Record's, and a session lock goes with the session it was taken
    # on — a sibling would then restore over this one mid-way.
    sig { returns(T::Boolean) }
    def call
      lock = Pg.connect
      begin
        lock.exec_params("SELECT pg_advisory_lock(hashtext($1))", [ LOCK_KEY ])
        # Re-check under the lock: a sibling process may have finished the
        # restore while this one waited.
        return false unless Staging.armed?

        restore!
        true
      ensure
        lock.close
      end
    end

    private

    sig { void }
    def restore!
      marker = Staging.marker
      preflight = Preflight.check(
        artifact_path: Staging.pending_artifact,
        confirm_identity: marker["confirm_identity"] == true
      )
      unless preflight.ok?
        # The marker stays armed: a half-diagnosed restore must block boot
        # loudly, not fall through to serving an empty instance.
        raise Error, "Restore preflight failed:\n  #{preflight.errors.join("\n  ")}"
      end
      manifest = T.must(preflight.manifest)

      work = Staging.work_dir
      FileUtils.rm_rf(work)
      work.mkpath

      extract_artifact(work)
      restore_primary(work, manifest)
      restore_files(work, manifest)
      write_receipt(manifest)

      Activity.record(
        source: "fog", event: "backup.restore.completed",
        summary: "Restored from artifact created #{manifest.created_at} (#{manifest.git_sha&.first(12)})",
        payload: { artifact_created_at: manifest.created_at, artifact_git_sha: manifest.git_sha }
      )
      Staging.disarm!
    end

    sig { params(work: Pathname).void }
    def extract_artifact(work)
      run!([ "tar", "-xf", Staging.pending_artifact.to_s, "-C", work.to_s ])
    end

    sig { params(work: Pathname, manifest: Manifest::Parsed).void }
    def restore_primary(work, manifest)
      component = manifest.components.find { |c| c["name"] == "primary" && c["kind"] == "db" }
      raise Error, "Artifact manifest lists no primary database component" if component.nil?

      dump = component_file(work, component)
      raise Error, "Artifact has no #{component["path"]}" unless dump.exist?

      run!([
        "pg_restore", "--clean", "--if-exists", "--no-owner", "--no-privileges", *Pg.connection_args, dump.to_s
      ], env: Pg.env)
      # This session's cached views of the schema are now stale; drop them so
      # anything after the restore reads the restored truth.
      ActiveRecord::Base.connection.schema_cache.clear!
      ActiveRecord::Base.connection.reconnect!
    end

    # A components-lite artifact (no files components) is legal.
    sig { params(work: Pathname, manifest: Manifest::Parsed).void }
    def restore_files(work, manifest)
      manifest.components.select { |c| c["kind"] == "files" }.each do |component|
        archive = component_file(work, component)
        raise Error, "Artifact has no #{component["path"]}" unless archive.exist?

        # Unpacks the storage/ tree relative to Rails.root. The producer
        # excluded storage/fog, so the staging area (including the artifact
        # being restored right now) is never touched.
        run!([ "tar", *self.class.unpack_flags(archive), "-xf", archive.to_s, "-C", Rails.root.to_s ])
      end
    end

    # tar flags for a file component, by extension: fog-backup/1 wrote
    # .tar.zst, fog-backup/2 writes plain .tar.
    sig { params(archive: Pathname).returns(T::Array[String]) }
    def self.unpack_flags(archive)
      name = archive.basename.to_s
      if name.end_with?(".tar.zst") then [ "--zstd" ]
      elsif name.end_with?(".tar") then []
      else raise Error, "File component #{name} is neither .tar nor .tar.zst"
      end
    end

    # The extracted file a manifest component names, refusing a path that
    # would reach outside the work directory.
    sig { params(work: Pathname, component: T::Hash[String, T.untyped]).returns(Pathname) }
    def component_file(work, component)
      path = component["path"].to_s
      root = work.cleanpath
      file = root.join(path).cleanpath
      if path.empty? || Pathname.new(path).absolute? || !file.to_s.start_with?("#{root}/")
        raise Error, "Component #{component["name"].inspect} has an unsafe path #{path.inspect}"
      end

      file
    end

    sig { params(manifest: Manifest::Parsed).void }
    def write_receipt(manifest)
      Staging.restore_root.mkpath
      Staging.receipt_path.write(JSON.pretty_generate(
        restored_at: Time.current.utc.iso8601,
        artifact_created_at: manifest.created_at,
        artifact_git_sha: manifest.git_sha,
        artifact_schema_version: manifest.schema_version.to_s,
        restored_by_git_sha: GlassVersion.sha
      ))
    end

    sig { params(argv: T::Array[String], env: T::Hash[String, String]).void }
    def run!(argv, env: {})
      Tool.run!(argv, timeout: RESTORE_TIMEOUT, error: Error, env: env)
    end
  end
end
