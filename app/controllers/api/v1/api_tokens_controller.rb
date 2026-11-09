# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Self-serve credential management: every user mints and revokes their
    # own tokens, and only their own. Admins get no extra reach here — a
    # token is as sensitive as the password that made it.
    class ApiTokensController < BaseController
      # A guest manages their own tokens like anyone else; a guest's token is
      # still read-only wherever it is used.
      skip_before_action :deny_guest_writes
      finds(:api_token, ApiToken) { current_user!.api_tokens }
      skip_before_action :set_api_token, only: %i[index create]

      sig { void }
      def index
        tokens = current_user!.api_tokens.order(created_at: :desc)
        render json: tokens.map { |token| ApiTokenSerializer.token_json(token) }
      end

      sig { void }
      def create
        days = params[:expires_in_days].presence&.to_i
        if days && !days.between?(1, ApiToken::MAX_EXPIRES_IN_DAYS)
          return render_errors("Expiry must be between 1 and #{ApiToken::MAX_EXPIRES_IN_DAYS} days")
        end

        scope = ApiToken::Scope.try_deserialize(params[:scope].to_s) || ApiToken::Scope::Full
        generated = ApiToken.generate(user: current_user!, name: params[:name].to_s.strip,
          expires_at: days&.days&.from_now, scope: scope)
        if generated.record.persisted?
          render json: ApiTokenSerializer.token_json(generated.record).merge(token: generated.token), status: :created
        else
          render_errors(generated.record)
        end
      end

      sig { void }
      def destroy
        api_token.destroy!
        head :no_content
      end
    end
  end
end
