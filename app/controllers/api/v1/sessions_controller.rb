# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class SessionsController < BaseController
      skip_before_action :require_auth, only: :create
      # Signing in and out is a guest's own business.
      skip_before_action :deny_guest_writes
      include LocalSignin

      # Rails 8 native rate limiting.
      rate_limit to: 10, within: 3.minutes, only: :create
      local_signin_only only: :create

      sig { void }
      def create
        user = User.find_by(email: params.require(:email).to_s.strip.downcase)
        if user&.authenticate(params.require(:password).to_s)
          render_new_session(user, device: params[:device].presence&.to_s)
        else
          render_errors("Invalid email or password", status: :unauthorized)
        end
      end

      sig { void }
      def destroy
        Current.api_session&.destroy
        head :no_content
      end
    end
  end
end
