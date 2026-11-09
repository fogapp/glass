# typed: strict
# frozen_string_literal: true

# The credential in a well-formed "Authorization: Bearer <token>" header, for
# every controller that authenticates one: the console API, MCP, and the fog
# contract surfaces. Header only, with no query-string fallback, because a
# token in a URL lands in every access log along the way. A bare token or any
# other scheme is nil.
module BearerToken
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::API }

  private

  sig { returns(T.nilable(String)) }
  def bearer_token
    header = request.headers["Authorization"].to_s
    return nil unless header.start_with?("Bearer ")

    header.split(" ", 2).last.presence
  end
end
