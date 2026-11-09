# typed: strict
# frozen_string_literal: true

# Deployed-revision resolution: fog stamps
# GIT_SHA into env via {{commit}}; the Dockerfile bakes a REVISION file as
# fallback; a git checkout answers in development.
module GlassVersion
  extend T::Sig

  # When this process came up — the "up for 3d" on Settings → About. Frozen
  # at load so every replica reports its own boot, not the request's.
  BOOTED_AT = T.let(Time.current, ActiveSupport::TimeWithZone)

  sig { returns(String) }
  def self.sha
    @sha ||= T.let(resolve, T.nilable(String))
  end

  sig { returns(String) }
  def self.short_sha = sha.first(12)

  sig { returns(String) }
  def self.resolve
    env = ENV["GIT_SHA"].presence
    return env if env

    revision_file = Rails.root.join("REVISION")
    return revision_file.read.strip if revision_file.exist?

    `git -C #{Rails.root} rev-parse HEAD 2>/dev/null`.strip.presence || "unknown"
  end
  private_class_method :resolve
end
