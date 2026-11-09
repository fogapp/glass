# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # First-run wizard endpoint for fresh fog deploys: creates the household +
    # first admin, exactly once. After any user exists this endpoint is a 403
    # and members join by invite only.
    class SetupController < BaseController
      include LocalSignin

      skip_before_action :require_auth

      rate_limit to: 5, within: 10.minutes, only: %i[create restore]
      # Once, ever: after any user exists both doors are a 403 and members
      # join by invite only.
      before_action :refuse_after_setup, only: %i[create restore]
      # On fog the wizard is off: the operator's first sign-in is the setup,
      # and fog restores its apps through fog-backup/2.
      local_signin_only only: %i[create restore], message: "Sign in with fog to set Glass up"

      # How the console should sign people in: Glass's own wizard and
      # passwords, fog alongside them, or fog alone (FogSignin).
      sig { void }
      def show
        FogSignin.attest_if_needed
        render json: {
          setup_required: User.count.zero? && !FogSignin.fog_only?,
          signin: { enabled: FogSignin.enabled?, fog_only: FogSignin.fog_only? }
        }
      end

      # The wizard's other door (fog-backup/2): instead of creating a fresh
      # household, upload a backup artifact and recover the previous instance.
      # On success the artifact is staged and armed; the app restarts itself
      # and the entrypoint performs the restore before serving again.
      sig { void }
      def restore
        upload = params[:artifact]
        unless upload.is_a?(ActionDispatch::Http::UploadedFile)
          return render_errors("Provide a backup artifact file", status: :bad_request)
        end

        preflight = FogBackup::StageRestore.call(
          upload: upload, confirm_identity: bool_param(:confirm_identity), staged_by: "setup-wizard",
          summary: "Restore armed from the setup wizard — restarting to recover"
        )
        unless preflight.ok?
          return render json: { errors: preflight.errors, preflight: FogSerializer.preflight_json(preflight) },
            status: :unprocessable_entity
        end

        FogBackup::Restart.schedule!
        render json: { restarting: true, preflight: FogSerializer.preflight_json(preflight) }
      end

      sig { void }
      def create
        ActiveRecord::Base.transaction do
          household = Household.create!(name: params.require(:household_name).to_s)
          user = User.register!(household: household, email: params.require(:email).to_s, name: params.require(:name).to_s,
            password: params.require(:password).to_s, role: User::Role::Admin)
          render_new_session(user, device: "setup")
        end
      end

      private

      sig { void }
      def refuse_after_setup
        render_errors("Setup already completed", status: :forbidden) if User.exists?
      end
    end
  end
end
