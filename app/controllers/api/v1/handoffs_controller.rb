# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The console's half of a fog sign-in: the callback put a one-time code
    # in the URL fragment; this exchanges it for the session's token, the
    # same shape a password sign-in answers with. The console-minted recovery
    # link (bin/rails glass:recovery_link) arrives the same way.
    class HandoffsController < BaseController
      skip_before_action :require_auth
      # Signing in is a guest's own business.
      skip_before_action :deny_guest_writes

      rate_limit to: 20, within: 1.minute, only: :create

      sig { void }
      def create
        session = ApiSession.redeem_handoff(params.require(:handoff).to_s)
        return render_errors("This sign-in link has expired; sign in again.", status: :unauthorized) if session.nil?

        render json: SessionSerializer.session_json(session, T.cast(session.user, User)), status: :created
      end
    end
  end
end
