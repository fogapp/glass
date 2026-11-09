# typed: strict
# frozen_string_literal: true

# Settings → About and the Dashboard's Instance card: which build is
# running, on what, against which database. The flat version fields are the
# build; `machine` adds fog's "This server" facts.
module AboutSerializer
  extend T::Sig

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def self.about_json
    state_dir = Rails.root.join("storage")
    {
      git_sha: GlassVersion.sha,
      git_sha_short: GlassVersion.short_sha,
      environment: Rails.env.to_s,
      ruby_version: RUBY_VERSION,
      rails_version: Rails.version,
      postgres_version: postgres_version,
      time_zone: Time.zone.name,
      booted_at: GlassVersion::BOOTED_AT.iso8601,
      machine: MachineInfo.report,
      storage: { state_dir: state_dir.to_s, **MachineInfo.disk_stats(state_dir.to_s) }
    }
  end

  # "18.1" — the server's own number, not the client library's. Nil when the
  # database is unreachable so the rest of the page still renders.
  sig { returns(T.nilable(String)) }
  def self.postgres_version
    ActiveRecord::Base.connection.select_value("SELECT current_setting('server_version')").to_s.split.first
  rescue ActiveRecord::ActiveRecordError, PG::Error
    nil
  end
  private_class_method :postgres_version
end
