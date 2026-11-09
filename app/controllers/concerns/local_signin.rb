# typed: strict
# frozen_string_literal: true

# The doors that make or open a Glass account of its own — a password, a
# passkey, an invite, the setup wizard — are shut when fog alone signs
# people in (FogSignin.fog_only?). `local_signin_only` declares which
# actions are such doors, and what a refused one says.
module LocalSignin
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::API }

  include ErrorEnvelope

  REFUSAL = "Glass signs people in with fog"

  module ClassMethods
    extend T::Sig
    extend T::Helpers

    requires_ancestor { T.class_of(ActionController::API) }

    sig { params(only: T.nilable(T.any(Symbol, T::Array[Symbol])), message: String).void }
    def local_signin_only(only: nil, message: REFUSAL)
      options = only ? { only: only } : {}
      before_action(**options) do
        T.bind(self, LocalSignin)
        refuse_local_signin(message) if FogSignin.fog_only?
      end
    end
  end

  mixes_in_class_methods(ClassMethods)

  private

  # A door that opened: a session for this person, answered as the console
  # stores it.
  sig { params(user: User, device: T.nilable(String)).void }
  def render_new_session(user, device:)
    session = ApiSession.generate!(user: user, device: device)
    render json: SessionSerializer.session_json(session, user), status: :created
  end

  sig { params(message: String).void }
  def refuse_local_signin(message)
    render_errors(message, status: :forbidden)
  end
end
