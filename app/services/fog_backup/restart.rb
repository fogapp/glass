# typed: strict
# frozen_string_literal: true

module FogBackup
  # Triggers the container restart that lets restore-on-boot consume an armed
  # artifact: signal PID 1 (thrust in the production image), the container
  # exits cleanly, docker's unless-stopped policy brings it back through the
  # entrypoint guard. Production-only on purpose — in development "restart the
  # server" is a human action, and specs must never kill their own process.
  module Restart
    extend T::Sig

    DELAY = T.let(1.5, Float)

    sig { void }
    def self.schedule!
      return unless Rails.env.production?

      Thread.new do
        sleep DELAY # let the HTTP response flush before the process goes away
        signal!
      end
    end

    sig { void }
    def self.signal!
      Process.kill("TERM", 1)
    rescue Errno::ESRCH, Errno::EPERM
      # Not PID 1's child (e.g. rails server outside the image) — take down
      # this process instead; the supervisor restarts it.
      Process.kill("TERM", Process.pid)
    end
  end
end
