# typed: strict
# frozen_string_literal: true

module FogBackup
  # One external tool run (ToolRunner) by the producer or the restorer:
  # anything but a clean exit raises `error` with what the tool said.
  module Tool
    extend T::Sig

    sig do
      params(
        argv: T::Array[String], timeout: Integer, error: T.class_of(StandardError),
        env: T::Hash[String, String], limit: Integer
      ).void
    end
    def self.run!(argv, timeout:, error:, env: {}, limit: 1000)
      result = ToolRunner.run(argv, timeout: timeout, env: env)
      return if result.success?

      raise error, "#{argv.first} exited #{result.status}: #{result.stderr.presence || result.stdout}".truncate(limit)
    end
  end
end
