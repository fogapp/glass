# typed: strict
# frozen_string_literal: true

module Auth
  # Sign in with fog — or with any OpenID provider OIDC_ISSUER names
  # (fog's docs/signin-contract.md). The flow is the shared
  # FogClient::Signin::Rails; Glass supplies what an identity means for its
  # accounts (SigninAdapter). Outside the bearer-token stack, like /ingest,
  # /mcp and /fog: these are the doors to it.
  class OidcController < ActionController::API
    extend T::Sig
    # The kit limits the link step, which takes an account's password, as
    # password sign-in is limited (10 in 3 minutes, "fog-link"): Glass adds
    # no limit of its own, which would only halve it.
    include FogClient::Signin::Rails

    private

    sig { returns(SigninAdapter) }
    def signin_adapter = SigninAdapter.new
  end
end
