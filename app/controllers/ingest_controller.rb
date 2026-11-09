# typed: strict
# frozen_string_literal: true

# glass-ingest/1 (docs/ingest-protocol.md): where every agent reports.
#
# Deliberately outside ApplicationController. The credential is an ingest
# key — write-only, one app — and none of the console's bearer stack
# applies; a console session is not a way in here and an ingest key is not a
# way in anywhere else.
#
# The reply is the control channel: `directives` carries the app's agent
# settings, so a change in the console reaches every process on its next
# flush.
class IngestController < ActionController::API
  extend T::Sig

  include BearerToken
  include ErrorEnvelope

  sig { void }
  def batch
    key = IngestKey.authenticate(bearer_token)
    return render_errors("Unknown or revoked ingest key", status: :unauthorized) if key.nil?

    verdict = Ingest::RateLimiter.check(key.id)
    unless verdict.allowed
      response.set_header("Retry-After", verdict.retry_after.to_s)
      return render_errors("Rate limit exceeded", status: :too_many_requests)
    end

    result = Ingest::Receiver.call(key: key, text: Ingest::Body.read(request))
    render json: {
      accepted: result.accepted, skipped: result.skipped, skewed: result.skewed,
      directives: T.must(key.app).directives
    }, status: :accepted
  rescue Ingest::Body::TooLarge => e
    render_errors(e.message, status: :content_too_large)
  rescue Ingest::Body::Unreadable, Ingest::Batch::Invalid => e
    render_errors(e.message, status: :bad_request)
  end
end
