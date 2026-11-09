# typed: false
# frozen_string_literal: true

# The fog-backup/2 boot tasks (fog's docs/backup-contract.md).
#
# fog:release is the app's release phase on fog (glass.fog.yaml): restore a
# staged artifact if one is armed, then db:prepare, which migrates a
# restored-from-older-code database forward.
#
# fog:restore_if_staged is the entrypoint guard (bin/docker-entrypoint) for
# container restarts that aren't deploys — the setup wizard's restore door:
# the same restore, and db:prepare only when it restored something, so a
# plain restart stays a plain restart.
namespace :fog do
  desc "Release phase: restore staged artifact if armed, then db:prepare"
  task release: :environment do
    FogBackup::Restorer.run_if_armed!
    Rake::Task["db:prepare"].invoke
  end

  desc "Restore a staged artifact if one is armed (entrypoint guard)"
  task restore_if_staged: :environment do
    Rake::Task["db:prepare"].invoke if FogBackup::Restorer.run_if_armed!
  end
end
