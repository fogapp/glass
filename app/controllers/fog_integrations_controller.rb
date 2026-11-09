# typed: strict
# frozen_string_literal: true

# The fog-integration/1 machine surface (fog's docs/integrations-contract.md):
# fog connects another app on the box to Glass through here. Outside the
# console auth stack like FogController, authenticated by FOG_API_TOKEN.
class FogIntegrationsController < ActionController::API
  extend T::Sig
  include FogContractAuth

  # POST /fog/integrations {consumer, offer} — mint the consumer's
  # credentials: 201 {id, secrets}, the secrets shown once.
  sig { void }
  def create
    minted = FogIntegrations.connect(consumer: params[:consumer].to_s, offer: params[:offer].to_s)
    render json: { id: minted.id, secrets: minted.secrets }, status: :created
  rescue FogIntegrations::Error => e
    render_errors(e.message, status: :unprocessable_content)
  end

  # GET /fog/integrations/:id
  sig { void }
  def show
    status = FogIntegrations.status(params[:id].to_s)
    render json: {
      id: status.id, active: status.active,
      created_at: status.created_at.iso8601, last_activity_at: status.last_activity_at&.iso8601
    }
  rescue FogIntegrations::NotFound => e
    render_errors(e.message, status: :not_found)
  end

  # DELETE /fog/integrations/:id — revoke. 404 once it is gone, which fog
  # takes as already done.
  sig { void }
  def destroy
    FogIntegrations.disconnect(params[:id].to_s)
    head :no_content
  rescue FogIntegrations::NotFound => e
    render_errors(e.message, status: :not_found)
  end
end
