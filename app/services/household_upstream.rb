# typed: strict
# frozen_string_literal: true

# An UpstreamHttpClient for infrastructure the household runs and expects to
# be private — fog's API and MCP surface, the ntfy relay on the fog network
# — never a URL handed to Glass by content. Such a server answers at once or
# not at all, so both timeouts are short, and it takes a bearer token (none,
# no header). An includer names its service and makes its call; the address,
# the token and the error it raises are kept here.
module HouseholdUpstream
  extend T::Sig
  extend T::Helpers

  requires_ancestor { UpstreamHttpClient }

  class Error < UpstreamHttpClient::Error; end

  sig { params(base_url: String, token: T.nilable(String)).void }
  def initialize(base_url:, token:)
    @base_url = T.let(base_url.chomp("/"), String)
    @token = token
  end

  # The one opt-in to the machine's own network, reviewed here once for
  # every includer: each reaches an address the operator or fog configured.
  sig { returns(T::Boolean) }
  def allow_private_addresses? = true # rubocop:disable Glass/NoUnreviewedPrivateEgress

  sig { returns(Integer) }
  def open_timeout = 3

  # A push or an event is a nicety on top of a durable row; a server that
  # can't answer in three seconds isn't worth holding a worker for.
  sig { returns(Integer) }
  def read_timeout = 3

  sig { returns(T.class_of(UpstreamHttpClient::Error)) }
  def error_class = Error

  sig { returns(T.nilable(String)) }
  def bearer_token = @token

  sig { params(request: ::Net::HTTPRequest).void }
  def authorize_request(request)
    token = bearer_token
    request["Authorization"] = "Bearer #{token}" if token
  end

  private

  sig { returns(String) }
  def base_url = @base_url
end
