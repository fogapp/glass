# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class ActivityController < BaseController
      sig { void }
      def index
        scope = household_entries
        if (severity = Activity::Severity.try_deserialize(params[:severity].to_s))
          scope = scope.where(severity: severity.serialize)
        end
        rows = ActivityEntrySerializer.preload(paginate(scope.recent))
        render json: rows.map { |e| ActivityEntrySerializer.entry_json(e) }
      end

      private

      sig { returns(ActiveRecord::Relation) }
      def household_entries
        ActivityEntry.where(household_id: [ current_household!.id, nil ])
      end
    end
  end
end
