# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class UsersController < BaseController
      sig { void }
      def me
        render json: UserSerializer.user_json(current_user!)
      end

      sig { void }
      def index
        users = current_household!.users.order(:created_at)
        render json: users.map { |u| UserSerializer.user_json(u) }
      end
    end
  end
end
