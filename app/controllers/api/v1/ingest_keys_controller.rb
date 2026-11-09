# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # An app's ingest keys (`GLASS_API_KEY`). Admin-only: a key is the right
    # to write into an app's telemetry.
    class IngestKeysController < BaseController
      before_action :require_admin!
      finds(:app, App, param: :app_id) { current_household!.apps }
      finds(:ingest_key, IngestKey) do
        T.bind(self, IngestKeysController)
        # `app` is the private reader `finds :app` defined above; the block
        # runs on the controller, so an implicit receiver reaches it.
        T.unsafe(self).send(:app).ingest_keys
      end
      skip_before_action :set_ingest_key, only: %i[index create]

      sig { void }
      def index
        render json: app.ingest_keys.order(created_at: :desc).map { |key| IngestKeySerializer.key_json(key) }
      end

      sig { void }
      def create
        generated = IngestKey.generate(app: app, name: params[:name].to_s.strip.presence || "key")
        return render_errors(generated.record) unless generated.record.persisted?

        Activity.record(source: "apps", event: "ingest_key.created",
          summary: "New ingest key “#{generated.record.name}” for #{app.name}", subject: generated.record)
        render json: IngestKeySerializer.key_json(generated.record).merge(token: generated.token), status: :created
      end

      # Revoked, not deleted: the row still says when the key was last used,
      # which is the first question after revoking one.
      sig { void }
      def destroy
        ingest_key.revoke!
        Activity.record(source: "apps", event: "ingest_key.revoked",
          summary: "Revoked ingest key “#{ingest_key.name}” for #{app.name}", subject: ingest_key)
        head :no_content
      end
    end
  end
end
