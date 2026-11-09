# typed: strict
# frozen_string_literal: true

# A new API session as its holder first sees it: the bearer token (shown
# this once) and who it signs in. Password sign-in, passkey sign-in, the
# setup wizard and accepting an invite all answer with it.
module SessionSerializer
  extend T::Sig

  sig { params(session: ApiSession, user: User).returns(T::Hash[Symbol, T.untyped]) }
  def self.session_json(session, user)
    token = session.token
    raise ArgumentError, "only a freshly minted session carries its token" if token.nil?

    { token: token, user: UserSerializer.user_json(user) }
  end
end
