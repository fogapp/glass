# typed: strict
# frozen_string_literal: true

# Instance-level settings that belong to the operator, not to an app: where
# alerts go, how much disk telemetry may use, how long each signal is kept.
#
# A singleton row (unique index on `true`). Read on hot paths, so it carries
# a short per-process memo — busted on commit and in
# specs.
class AppSetting < ApplicationRecord
  extend T::Sig

  CACHE_TTL = T.let(30.seconds, ActiveSupport::Duration)
  # Below this the budget would evict the day being written.
  MIN_DISK_BUDGET_MB = 256
  # How much of a connection test's message the row keeps.
  TEST_MESSAGE_LIMIT = 250

  # ntfy's access token, when the topic wants one — entered in Settings and
  # never serialized back (SettingsSerializer says only whether it is set).
  encrypts :ntfy_token
  # An MCP token minted in fog's Settings › AI access: read-only there, and
  # everything Level 1 of the fog integration needs.
  encrypts :fog_token

  validates :disk_budget_mb, numericality: { only_integer: true, greater_than_or_equal_to: MIN_DISK_BUDGET_MB }
  validate :retention_days_are_known_tables

  # Fog names a person removed from Glass (Fog::Sync leaves them alone):
  # only names fog could have sent, each once, in a stable order.
  normalizes :fog_ignored_apps, with: ->(names) { Array(names).map { |name| name.to_s.strip.downcase }.grep(App::SLUG_FORMAT).uniq.sort }

  sig { returns(AppSetting) }
  def self.current
    first || create!
  rescue ActiveRecord::RecordNotUnique
    T.must(first)
  end

  sig { returns(AppSetting) }
  def self.cached
    cached_at = @cached_at
    memo = @cached
    return memo if memo && cached_at && cached_at > CACHE_TTL.ago

    @cached = T.let(current, T.nilable(AppSetting))
    @cached_at = T.let(Time.current, T.nilable(ActiveSupport::TimeWithZone))
    T.must(@cached)
  end

  sig { void }
  def self.bust_cache!
    @cached = nil
    @cached_at = nil
  end

  after_commit { self.class.bust_cache! }

  sig { params(name: String).returns(T::Boolean) }
  def fog_ignores?(name) = fog_ignored_apps.include?(name.downcase)

  # Removing an app fog still runs has to be remembered, or the next sync
  # makes it again.
  sig { params(name: String).void }
  def ignore_fog_app!(name)
    update!(fog_ignored_apps: fog_ignored_apps + [ name ]) unless fog_ignores?(name)
  end

  sig { params(names: T::Array[T.nilable(String)]).void }
  def follow_fog_apps!(names)
    kept = fog_ignored_apps - names.compact.map(&:downcase)
    update!(fog_ignored_apps: kept) if kept != fog_ignored_apps
  end

  # How long a telemetry table's days are kept: what a person set, else the
  # table's own default.
  sig { params(table: Telemetry::Tables::Table).returns(Integer) }
  def retention_for(table)
    override = retention_days[table.name]
    override.is_a?(Integer) && override.positive? ? override : table.retention_days
  end

  # The one writer for a Settings "Test" button's outcome, kept so the
  # screen can say how the last test went without running it again. The
  # columns' prefix names the connection: `last_test_*` for ntfy,
  # `fog_last_test_*` for fog.
  sig { params(ok: T::Boolean, message: String, prefix: String).void }
  def record_test!(ok, message, prefix: "")
    update!("#{prefix}last_tested_at" => Time.current, "#{prefix}last_test_ok" => ok,
      "#{prefix}last_test_message" => message.truncate(TEST_MESSAGE_LIMIT))
  end

  private

  sig { void }
  def retention_days_are_known_tables
    retention_days.each do |name, days|
      table = Telemetry::Tables.find(name.to_s)
      next errors.add(:retention_days, "names an unknown table: #{name}") if table.nil?
      next if days.is_a?(Integer) && days.between?(1, table.max_retention_days)

      errors.add(:retention_days, "for #{name} must be between 1 and #{table.max_retention_days} days")
    end
  end
end
