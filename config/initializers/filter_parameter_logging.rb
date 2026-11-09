# typed: false

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # No Glass endpoint takes an `auth` param today; one that did would carry a
  # credential, and `auth` matches none of the partial patterns above.
  :auth,
  # Fog sign-in (FogClient::Signin::Rails): the callback's authorization
  # code, the link step's sealed identity, and the one-time handoff code the
  # console trades for a session. (Exactly `code`: the only other params so
  # named are invite codes, credentials too.)
  /\Acode\z/, :pending, :handoff
]
