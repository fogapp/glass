# typed: strict
# frozen_string_literal: true

# The fog-backup/2 machine surface (fog's docs/backup-contract.md): fog drives
# backups and restores through here. Deliberately outside the console auth
# stack, like McpController — the credential is FOG_API_TOKEN, a per-app
# shared secret fog injects at deploy, so the surface works on a fresh
# instance with zero users (which is exactly when a restore needs it).
class FogController < ActionController::API
  extend T::Sig
  include FogContractAuth

  # GET /fog/backup — the descriptor: who this app is, what a backup of it
  # contains, whether the instance is fresh, and the last restore receipt.
  sig { void }
  def descriptor
    render json: FogSerializer.descriptor_json
  end

  # POST /fog/backup — start producing an artifact. 202 with the job to
  # poll; 409 with the running job when one is already producing (fog
  # adopts it rather than stacking a second dump).
  sig { void }
  def create_backup
    outcome = FogBackup::Trigger.call(household: Household.instance)
    render json: { job: outcome.job_run.id }, status: outcome.started ? :accepted : :conflict
  end

  # GET /fog/backup/jobs/:id
  sig { void }
  def job_status
    run = producer_run
    return render_not_found if run.nil?

    render json: FogSerializer.job_json(run)
  end

  # GET /fog/backup/jobs/:id/artifact — the download fog verifies against
  # the job status' {bytes, sha256} claim.
  sig { void }
  def artifact
    run = producer_run
    return render_not_found if run.nil?

    path = FogBackup::Staging.artifact_path(run.id)
    return render_not_found unless run.status_enum == JobRun::Status::Succeeded && path.exist?

    send_file path.to_s, type: "application/x-tar",
      filename: "glass-#{T.must(run.finished_at).utc.strftime("%Y%m%d-%H%M%S")}.fogpack.tar"
  end

  # DELETE /fog/backup/jobs/:id — fog collected (and verified) the artifact;
  # drop the staged copy.
  sig { void }
  def destroy_job
    run = producer_run
    return render_not_found if run.nil?

    FileUtils.rm_rf(FogBackup::Staging.job_dir(run.id))
    head :no_content
  end

  # POST /fog/restore — stage an artifact and arm restore-on-boot. Multipart
  # upload (field `artifact`), or staged:true when the file has already been
  # placed at the staging path by whoever holds the volume (fog does, for
  # restore-at-create). Fresh instances only: restoring over live data goes
  # through fog, which stops the app and stages directly.
  sig { void }
  def restore
    unless fresh_instance?
      return render_errors("This instance already has data — in-place restores go through fog, which stops the app first",
        status: :conflict)
    end

    staged = ActiveModel::Type::Boolean.new.cast(params[:staged])
    upload = params[:artifact]
    upload = nil unless upload.is_a?(ActionDispatch::Http::UploadedFile)
    if !staged && upload.nil?
      return render_errors("Provide an artifact upload or staged: true", status: :bad_request)
    end

    preflight = FogBackup::StageRestore.call(
      upload: staged ? nil : upload,
      confirm_identity: ActiveModel::Type::Boolean.new.cast(params[:confirm_identity]) || false,
      staged_by: "fog-api", summary: "Restore armed from staged artifact — restart to recover"
    )
    return render_errors(preflight.errors) unless preflight.ok?

    render json: { preflight: FogSerializer.preflight_json(preflight), restart_required: true }
  end

  private

  UUID_RE = T.let(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, Regexp)

  sig { returns(T.nilable(JobRun)) }
  def producer_run
    id = params[:id].to_s
    # Postgres raises on non-UUID input to a uuid column; a garbage job id
    # is a 404, not a 500.
    return nil unless id.match?(UUID_RE)

    JobRun.find_by(id: id, job_key: ProduceBackupJob::JOB_KEY)
  end

  sig { void }
  def render_not_found
    render_errors("no such producer job", status: :not_found)
  end

  sig { returns(T::Boolean) }
  def fresh_instance?
    !User.exists?
  end
end
