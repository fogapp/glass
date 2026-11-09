# typed: strict
# frozen_string_literal: true

# The provider half of fog-integration/1 (fog's docs/integrations-contract.md):
# fog asks Glass for what another app on the box needs, Glass mints it for
# that app alone, and fog puts it in the app's environment.
#
# One offer, so connecting an app to Glass is one click: `monitoring` mints
# an ingest key for the app's App, so it reports to Glass, and a read-only
# API token, so it can show what Glass holds (a dashboard's widgets). An app that
# only reports leaves the token unread. Choosing the app on fog's
# Integrations tab is the operator's say-so — fog's operators are Glass's
# admins — and fog authenticates with FOG_API_TOKEN. The token is in the name
# of the household's first admin, as a token has to be in someone's.
#
# An integration's id is its FogIntegration's: fog keeps it opaque and names
# it again to read the status of, or revoke, the integration.
module FogIntegrations
  extend T::Sig

  class Error < StandardError; end
  class NotFound < Error; end

  MONITORING = "monitoring"
  OFFERS = T.let([ MONITORING ].freeze, T::Array[String])
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  class Minted < T::Struct
    const :id, String
    const :secrets, T::Hash[String, String]
  end

  class Status < T::Struct
    const :id, String
    const :active, T::Boolean
    const :created_at, ActiveSupport::TimeWithZone
    const :last_activity_at, T.nilable(ActiveSupport::TimeWithZone)
  end

  sig { params(consumer: String, offer: String).returns(Minted) }
  def self.connect(consumer:, offer:)
    raise Error, "Glass offers no #{offer.inspect} — it offers #{OFFERS.join(", ")}" unless OFFERS.include?(offer)
    raise Error, "#{consumer.inspect} is not an app name" unless App::SLUG_FORMAT.match?(consumer)

    household = Household.instance
    raise Error, "Glass has no household yet — open it and finish setup first" if household.nil?

    owner = User.where(household: household, role: User::Role::Admin.serialize).order(:created_at).first
    raise Error, "Glass has no admin yet — sign in to Glass once first" if owner.nil?

    ActiveRecord::Base.transaction do
      app = app_for(household, consumer)
      key = IngestKey.generate(app: app, name: "fog integration")
      token = ApiToken.generate(user: owner, name: "fog: #{consumer}", scope: ApiToken::Scope::Read)
      [ key.record, token.record ].each do |record|
        raise Error, record.errors.full_messages.to_sentence unless record.persisted?
      end
      integration = FogIntegration.create!(household: household, consumer: consumer,
        ingest_key: key.record, api_token: token.record)

      Activity.record(source: "fog", event: "integration.connected", household_id: household.id,
        summary: "fog connected #{app.name} to Glass: a new ingest key and a read-only API token")
      Minted.new(id: integration.id, secrets: { "GLASS_API_KEY" => key.token, "GLASS_READ_TOKEN" => token.token })
    end
  end

  # Active while both credentials still work. Last activity is the later of
  # the app reporting and the app reading.
  sig { params(id: String).returns(Status) }
  def self.status(id)
    integration = find(id)
    key = integration.ingest_key
    token = integration.api_token
    active = !key.nil? && !key.revoked? && !token.nil? && !token.expired?
    reported = key&.last_used_at && key.app&.last_seen_at
    Status.new(id: id, active: active, created_at: integration.created_at,
      last_activity_at: [ reported, token&.last_used_at ].compact.max)
  end

  # The ingest key is revoked, not deleted, as from Settings › Apps: the row
  # still says when it was last used. The read token goes, as a person's own
  # revoke would.
  sig { params(id: String).void }
  def self.disconnect(id)
    integration = find(id)
    key = integration.ingest_key
    token = integration.api_token
    return if (key.nil? || key.revoked?) && token.nil?

    key.revoke! if key && !key.revoked?
    token&.destroy!
    Activity.record(source: "fog", event: "integration.revoked", household_id: integration.household_id,
      summary: "fog disconnected #{integration.consumer} from Glass: its ingest key and read token are revoked")
  end

  # The App fog's sync would match the consumer to, or a new one.
  # Connecting an app a person removed from Glass wants it back.
  sig { params(household: Household, name: String).returns(App) }
  def self.app_for(household, name)
    AppSetting.current.follow_fog_apps!([ name ])
    T.must(App.adopt_from_fog!(household, name, create: true))
  end
  private_class_method :app_for

  sig { params(id: String).returns(FogIntegration) }
  def self.find(id)
    raise NotFound, "no such integration" unless id.match?(UUID)

    integration = FogIntegration.unscoped.includes(:api_token, ingest_key: :app).find_by(id: id)
    raise NotFound, "no such integration" if integration.nil?

    integration
  end
  private_class_method :find
end
