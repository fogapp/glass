# typed: strict
# frozen_string_literal: true

module AppSerializer
  extend T::Sig

  sig { params(app: App, health: T.nilable(AppHealth::Summary)).returns(T::Hash[Symbol, T.untyped]) }
  def self.app_json(app, health: nil)
    {
      id: app.id, slug: app.slug, name: app.name, color_slot: app.color_slot, fog_name: app.fog_name,
      identity_mode: app.identity_mode, link_template: app.link_template,
      fog: app.fog_name ? app.fog_state.slice("rev", "healthy", "state", "hosts") : nil,
      # The effective settings (defaults under what was changed) — what an
      # agent is actually being told.
      agent_settings: app.settings.to_h,
      first_seen_at: app.first_seen_at&.to_f, last_seen_at: app.last_seen_at&.to_f,
      reporting: (health&.live_processes || 0).positive?,
      live_processes: health&.live_processes || 0,
      release: health&.release,
      # request, job, run …: which sections its page has something to show in.
      kinds: health&.kinds || [],
      created_at: app.created_at.to_f
    }
  end
end
