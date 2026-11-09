# typed: false
# frozen_string_literal: true

# The Rails half of fog sign-in (vendor/gems/fog-client): the shared
# controller Auth::OidcController includes. Loaded unconditionally; without
# OIDC_ISSUER its actions answer 404 and the console shows only Glass's own
# sign-in.
require "fog_client/signin/rails"
