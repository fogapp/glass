# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Flamegraphs. The query language is the Explorer's —
    # `app:hook transaction:"WantsController#index" state:running` — over
    # the profile samples; the answer is the merged call tree.
    class ProfilesController < BaseController
      allow_read_scope :flamegraph
      skip_before_action :deny_guest_writes, only: :flamegraph

      MAX_RANGE = Profiles::Flamegraph::MAX_RANGE

      # POST /api/v1/profiles/flamegraph
      #   { from, to, filter, baseline: { from, to, filter } }
      sig { void }
      def flamegraph
        range = profile_range(params)
        baseline = params[:baseline].respond_to?(:to_unsafe_h) ? profile_range(params[:baseline], default_filter: range.filter) : nil
        render json: Profiles::Flamegraph.new(
          context: Query::Context.new(current_household!), range: range, baseline: baseline
        ).build
      end

      private

      # Both bounds are required, as wide as a flamegraph may be.
      sig { params(source: T.untyped, default_filter: String).returns(Profiles::Flamegraph::Range) }
      def profile_range(source, default_filter: "")
        from, to = range_param(source, default: nil, max: MAX_RANGE)
        filter = source.key?(:filter) ? source[:filter].to_s : default_filter
        Profiles::Flamegraph::Range.new(from: from, to: to, filter: filter)
      end
    end
  end
end
