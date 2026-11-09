# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class AboutController < BaseController
      sig { void }
      def show
        render json: AboutSerializer.about_json
      end
    end
  end
end
