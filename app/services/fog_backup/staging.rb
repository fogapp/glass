# typed: strict
# frozen_string_literal: true

module FogBackup
  # Path conventions for the fog-backup/2 contract (fog's docs/backup-contract.md).
  #
  # Everything lives under storage/fog — on a fog deploy that's the managed
  # storage volume, so staged artifacts and the arming marker survive container
  # replacement, which is exactly what restore-on-boot depends on. The producer
  # excludes this subtree from the artifact so a backup never contains staged
  # backups.
  module Staging
    extend T::Sig

    # Producer staging older than this is presumed abandoned (fog crashed
    # between produce and download) and swept.
    STALE_AFTER = T.let(24.hours, ActiveSupport::Duration)

    sig { returns(Pathname) }
    def self.root = Rails.root.join("storage", "fog")

    # ---- producer side ----

    sig { returns(Pathname) }
    def self.backup_root = root.join("backup")

    sig { params(job_id: String).returns(Pathname) }
    def self.job_dir(job_id) = backup_root.join(job_id)

    sig { params(job_id: String).returns(Pathname) }
    def self.artifact_path(job_id) = job_dir(job_id).join("artifact.tar")

    # The producer's claim about the finished artifact ({bytes, sha256}),
    # served back through the job-status endpoint for fog to verify against.
    sig { params(job_id: String).returns(Pathname) }
    def self.artifact_info_path(job_id) = job_dir(job_id).join("artifact.json")

    sig { params(job_id: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.artifact_info(job_id) = read_json(artifact_info_path(job_id))

    sig { void }
    def self.sweep_stale!
      return unless backup_root.exist?

      backup_root.children.each do |dir|
        FileUtils.rm_rf(dir) if dir.mtime < STALE_AFTER.ago
      rescue Errno::ENOENT
        nil # already gone — a concurrent sweep or DELETE won the race
      end
    end

    # ---- restore side ----

    sig { returns(Pathname) }
    def self.restore_root = root.join("restore")

    sig { returns(Pathname) }
    def self.pending_artifact = restore_root.join("pending.tar")

    # The arming marker. Restore-on-boot runs only when this exists and says
    # armed — a half-uploaded artifact without a marker is inert.
    sig { returns(Pathname) }
    def self.pending_marker = restore_root.join("pending.json")

    sig { returns(Pathname) }
    def self.receipt_path = restore_root.join("receipt.json")

    sig { returns(Pathname) }
    def self.work_dir = restore_root.join("work")

    sig { returns(T::Boolean) }
    def self.armed? = pending_artifact.exist? && marker["armed"] == true

    sig { params(confirm_identity: T::Boolean, staged_by: String).void }
    def self.arm!(confirm_identity:, staged_by:)
      restore_root.mkpath
      pending_marker.write(JSON.pretty_generate(
        armed: true,
        confirm_identity: confirm_identity,
        staged_by: staged_by,
        staged_at: Time.current.iso8601
      ))
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def self.marker = read_json(pending_marker) || {}

    sig { void }
    def self.disarm!
      FileUtils.rm_f(pending_marker)
      FileUtils.rm_f(pending_artifact)
      FileUtils.rm_rf(work_dir)
    end

    # The receipt outlives the staging files: it's the descriptor's
    # last_restore answer and the proof a recovery actually happened.
    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.receipt = read_json(receipt_path)

    # A JSON object written here, or nil when it is absent or unreadable —
    # a torn write reads as never written.
    sig { params(path: Pathname).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.read_json(path)
      return nil unless path.exist?

      parsed = JSON.parse(path.read)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end
end
