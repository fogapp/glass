# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The apps that report. Anyone signed in may read them; adding, changing
    # and removing one is the admin's.
    class AppsController < BaseController
      before_action :require_admin!, only: %i[create update destroy]
      finds(:app, App, param: :id) { current_household!.apps }
      skip_before_action :set_app, only: %i[index create]

      sig { void }
      def index
        apps = current_household!.apps.order(:name).to_a
        health = AppHealth.for(apps)
        render json: apps.map { |record| AppSerializer.app_json(record, health: health[record.telemetry_id]) }
      end

      sig { void }
      def show
        render json: AppSerializer.app_json(app, health: AppHealth.for([ app ])[app.telemetry_id])
      end

      # Creating an app also mints its first ingest key, returned this once:
      # the two values an app needs are the URL and this.
      sig { void }
      def create
        record = current_household!.apps.new(app_params)
        generated = T.let(nil, T.nilable(DigestedToken::Generated[IngestKey]))
        App.transaction do
          record.save!
          generated = IngestKey.generate(app: record, name: "default")
        end
        follow_in_fog(record)
        Activity.record(source: "apps", event: "app.created", summary: "Added #{record.name}", subject: record)
        render json: AppSerializer.app_json(record).merge(ingest_key: T.must(generated).token), status: :created
      end

      sig { void }
      def update
        app.assign_attributes(app_params)
        overrides = params[:agent_settings]
        if overrides.respond_to?(:to_unsafe_h)
          app.agent_settings = app.agent_settings.merge(AgentSettings.coerce_overrides(overrides.to_unsafe_h))
        end
        app.save!
        follow_in_fog(app)
        render json: AppSerializer.app_json(app, health: AppHealth.for([ app ])[app.telemetry_id])
      end

      # The configuration goes; what the app reported stays until it ages
      # out, unreachable (telemetry is keyed by an id nothing names any more).
      # An app fog runs is also remembered as removed, or the next sync
      # would bring it straight back (Fog::Sync).
      sig { void }
      def destroy
        app.destroy!
        fog_name = app.fog_name
        AppSetting.current.ignore_fog_app!(fog_name) if fog_name.present?
        Activity.record(source: "apps", event: "app.removed", summary: "Removed #{app.name}")
        head :no_content
      end

      private

      # An app added or renamed by hand to a name removed earlier is wanted
      # again: the sync will match it, so it is no longer "removed".
      sig { params(record: App).void }
      def follow_in_fog(record)
        AppSetting.current.follow_fog_apps!([ record.slug, record.fog_name ])
      end

      sig { returns(ActionController::Parameters) }
      def app_params
        permitted = params.permit(:name, :slug, :color_slot, :fog_name, :identity_mode, :link_template)
        mode = permitted[:identity_mode]
        permitted.delete(:identity_mode) if mode && App::IdentityMode.try_deserialize(mode.to_s).nil?
        permitted
      end
    end
  end
end
