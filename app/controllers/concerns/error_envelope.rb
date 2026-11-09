# typed: strict
# frozen_string_literal: true

# The only error envelope is { errors: [...] } (cop-enforced), for every
# controller — the bearer stack's and the ones outside it (fog's contract
# surface, passkey sign-in). The one sanctioned exception is a connection
# test's { ok:, message: } answer (BaseController#render_connection_test).
module ErrorEnvelope
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::API }

  private

  sig { params(source: T.untyped, status: Symbol).void }
  def render_errors(source, status: :unprocessable_entity)
    messages =
      case source
      when String then [ source ]
      when Array then source.map(&:to_s)
      when ActiveModel::Errors then source.full_messages
      else
        model_errors = source.respond_to?(:errors) ? source.errors : nil
        model_errors.is_a?(ActiveModel::Errors) ? model_errors.full_messages : [ source.to_s ]
      end
    render json: { errors: messages }, status: status
  end
end
