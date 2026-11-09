# typed: false
# frozen_string_literal: true

# fog's own doors (/fog/*) answer one bearer, the FOG_API_TOKEN fog injects.
# `include_context "with fog token"` sets it for each example and gives
# `fog_headers` to knock with.
RSpec.shared_context "with fog token" do
  let(:token) { "fog-test-token" }

  around do |example|
    previous = ENV["FOG_API_TOKEN"]
    ENV["FOG_API_TOKEN"] = token
    example.run
  ensure
    ENV["FOG_API_TOKEN"] = previous
  end

  def fog_headers = bearer(token)
end
