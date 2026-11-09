# typed: strict
# frozen_string_literal: true

module FogBackup
  # Stage a backup artifact and arm restore-on-boot (fog-backup/2): the
  # uploaded file (or the one fog already placed at the staging path) is
  # preflighted, and only an artifact that passes is armed. A refused
  # artifact is disarmed at once — it must not sit staged where a later
  # boot could misread it as intentional. The setup wizard and fog's
  # POST /fog/restore both come through here; each answers in its own shape
  # and decides what happens next (the wizard restarts the app itself).
  module StageRestore
    extend T::Sig

    # `upload` nil means the artifact is already at the staging path.
    sig do
      params(upload: T.nilable(ActionDispatch::Http::UploadedFile), confirm_identity: T::Boolean, staged_by: String,
        summary: String).returns(Preflight::Result)
    end
    def self.call(upload:, confirm_identity:, staged_by:, summary:)
      Staging.restore_root.mkpath
      FileUtils.mv(upload.tempfile.path, Staging.pending_artifact.to_s) if upload

      preflight = Preflight.check(artifact_path: Staging.pending_artifact, confirm_identity: confirm_identity)
      unless preflight.ok?
        Staging.disarm!
        return preflight
      end

      Staging.arm!(confirm_identity: confirm_identity, staged_by: staged_by)
      Activity.record(source: "fog", event: "backup.restore.armed", summary: summary)
      preflight
    end
  end
end
