# typed: strict
# frozen_string_literal: true

# Produces one fog-backup/2 artifact into staging (fog's docs/backup-contract.md).
# Triggered by fog's POST /fog/backup (FogBackup::Trigger) or from the console
# jobs page; fog polls the JobRun this rides on and downloads the result.
class ProduceBackupJob < ApplicationJob
  extend T::Sig
  include ManagedJob

  JOB_KEY = "produce_backup"
  DESCRIPTION = "Build a full fog-backup/2 artifact (database dump + file state) into staging for fog to collect."

  queue_as :backup

  # Fail fast instead of the polynomial default: fog is polling for a verdict,
  # and a dump that failed once fails the same way three retries later —
  # each retry costing a full pg_dump of the archive.
  retry_on StandardError, attempts: 1

  # A second dump racing the first would double disk under staging and
  # thrash the database for nothing. Two hours: the dump and the archive are
  # each allowed an hour (FogBackup::Producer's timeouts).
  limits_concurrency key: JOB_KEY, duration: 2.hours

  sig { override.returns(T.nilable(String)) }
  def run_job = FogBackup::Producer.new(job_run: job_run).call
end
