# typed: strict
# frozen_string_literal: true

# Serves the built console for any non-API path so client-side routes survive
# a hard refresh. Deliberately outside ApplicationController — no auth, it's
# just the shell; the API enforces access.
class SpaController < ActionController::Base
  extend T::Sig

  skip_forgery_protection

  sig { void }
  def show
    index = Rails.public_path.join("index.html")
    if index.exist?
      render file: index, layout: false, content_type: "text/html"
    else
      render plain: "Console not built. Run `npm --prefix frontend run build`.", status: :not_found
    end
  end
end
