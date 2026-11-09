# typed: strict
# frozen_string_literal: true

# Something that reports to Glass: one of the fleet's apps. Configuration
# lives here; everything it ever reported lives in the telemetry database,
# keyed by `telemetry_id`.
class App < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  # Who a visitor is recorded as. The default is
  # pseudonymous: a stable hash, so "the same person came back" is knowable
  # and "which person" is not.
  class IdentityMode < T::Enum
    include ApplicationEnum
    enums do
      Anonymous = new("anonymous")
      Pseudonymous = new("pseudonymous")
      Named = new("named")
    end
  end

  # The categorical chart slots (frontend: --color-series-1..8). An app's
  # colour is assigned once and never cycles.
  COLOR_SLOTS = T.let((1..8).to_a.freeze, T::Array[Integer])
  SLUG_FORMAT = /\A[a-z0-9][a-z0-9_-]{0,38}\z/
  # What a link template may name: the trace, and what the app's own records
  # are keyed by, which it sends as attributes of a unit of work.
  LINK_PLACEHOLDER = /\{([a-z_]{1,40})\}/
  LINK_FORMAT = %r{\Ahttps?://[^\s<>"]+\z}

  has_many :ingest_keys, dependent: :destroy

  attribute :identity_mode, IdentityMode

  normalizes :slug, with: ->(slug) { slug.to_s.strip.downcase }

  validates :name, presence: true, length: { maximum: 60 }
  validates :slug, presence: true, uniqueness: { scope: :household_id },
    format: { with: SLUG_FORMAT, message: "may only hold lowercase letters, digits, - and _" }
  validates :color_slot, inclusion: { in: COLOR_SLOTS }
  # A link out of Glass into the app's own console, for what Glass is never
  # sent: `{run}`, `{session}`, `{trace}` and any attribute key are filled
  # from the row the link is on.
  normalizes :link_template, with: ->(value) { value.to_s.strip.presence }
  validates :link_template, length: { maximum: 300 },
    format: { with: LINK_FORMAT, message: "must be an http(s) address, like https://assistant.example.net/traces/{run}" },
    allow_nil: true

  before_validation :assign_color_slot, on: :create
  # An app added by name alone is known by that name, as a slug.
  before_validation :default_slug, on: :create

  # The app fog's name for it points at: matched by fog name, else by slug
  # (and known by fog's name from then on), else — when `create` — made,
  # known by fog's name, and silent until it reports. nil when there is none
  # and none is to be made. Fog::Sync and FogIntegrations both ask here, so
  # an app fog syncs and an app fog connects are the same row.
  sig { params(household: Household, name: String, create: T::Boolean).returns(T.nilable(App)) }
  def self.adopt_from_fog!(household, name, create:)
    apps = unscoped.where(household_id: household.id)
    existing = apps.find_by(fog_name: name) || apps.find_by(slug: name)
    if existing
      existing.update!(fog_name: name) if existing.fog_name != name
      return existing
    end
    return nil unless create

    create!(household: household, slug: name, name: name.humanize, fog_name: name)
  end

  sig { returns(AgentSettings) }
  def settings = AgentSettings.from_overrides(agent_settings)

  # `directives` in an ingest reply (docs/ingest-protocol.md): the agent
  # settings, plus what the agent needs to know about the app itself.
  # `profile_now` is always nil until the console has a button for it:
  # the protocol, the agents and profile_samples'
  # request_id already carry it end to end.
  sig { returns(T::Hash[String, T.untyped]) }
  def directives = settings.to_h.merge("identity" => identity_mode, "profile_now" => nil)

  # Stamped from ingest, at most once a minute — this row is read on every
  # batch and must not be written on every batch.
  sig { params(now: ActiveSupport::TimeWithZone).void }
  def record_seen!(now: Time.current)
    stamp_throttled!(:last_seen_at, every: 1.minute, now: now, also: { first_seen_at: first_seen_at || now })
  end

  private

  sig { void }
  def default_slug
    self.slug = name.to_s.parameterize if slug.blank?
  end

  # The least-used slot, so the first eight apps are all distinguishable.
  sig { void }
  def assign_color_slot
    return if color_slot_changed? && COLOR_SLOTS.include?(color_slot)

    used = App.unscoped.where(household_id: household_id).group(:color_slot).count
    self.color_slot = T.must(COLOR_SLOTS.min_by { |slot| [ used.fetch(slot, 0), slot ] })
  end
end
