# typed: strict
# frozen_string_literal: true

# The one auth rule shared by every fog-contract surface — backup,
# federation, files: a constant-time compare of the presented bearer
# credential against the fog-injected FOG_API_TOKEN. No token configured
# means the surface does not exist. Only a well-formed "Bearer <token>" is
# accepted (BearerToken); a bare token or another scheme is refused.
module FogContractAuth
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::API }

  include BearerToken
  include ErrorEnvelope

  included do
    T.bind(self, T.class_of(ActionController::API))
    before_action :authenticate_fog!
  end

  private

  sig { void }
  def authenticate_fog!
    expected = FogClient.token
    presented = bearer_token
    if expected.nil? || presented.nil? ||
        !ActiveSupport::SecurityUtils.secure_compare(expected, presented)
      render_errors("unauthorized", status: :unauthorized)
    end
  end
end
