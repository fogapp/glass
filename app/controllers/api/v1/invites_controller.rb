# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class InvitesController < BaseController
      include LocalSignin

      skip_before_action :require_auth, only: :accept
      before_action :require_admin!, only: :create

      rate_limit to: 10, within: 3.minutes, only: :accept
      # An invite makes a password account; on fog, people arrive through
      # fog instead (the app's Sign-in tab there decides who may).
      local_signin_only only: :accept

      sig { void }
      def create
        role = User::Role.try_deserialize(params[:role].to_s) || User::Role::Member
        invite = InviteCode.generate!(household: current_household!, created_by: current_user!, role: role)
        render json: InviteSerializer.invite_json(invite), status: :created
      end

      sig { void }
      def accept
        invite = InviteCode.find_by(code: params.require(:code).to_s)
        return render_errors("Invite is invalid or expired", status: :unprocessable_entity) unless invite&.usable?

        household = T.cast(invite.household, Household)
        ActiveRecord::Base.transaction do
          user = User.register!(household: household, email: params.require(:email).to_s, name: params.require(:name).to_s,
            password: params.require(:password).to_s, role: invite.role_enum)
          invite.consume!
          render_new_session(user, device: "invite")
        end
      rescue InviteCode::AlreadyUsed
        render_errors("Invite is invalid or expired", status: :unprocessable_entity)
      end
    end
  end
end
