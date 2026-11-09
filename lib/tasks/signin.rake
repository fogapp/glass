# typed: false
# frozen_string_literal: true

namespace :glass do
  # Break-glass for fog-only Glass (fog's docs/signin-contract.md): when
  # fog itself is broken, the operator — who has a shell, by definition —
  # mints a single-use link that signs in Glass's first admin. Nothing
  # reachable from the network can do this, and Glass keeps no standing
  # password for it.
  desc "Print a single-use, ten-minute sign-in link for Glass's first admin"
  task recovery_link: :environment do
    admin = User.where(role: User::Role::Admin.serialize).order(:created_at).first
    abort "Glass has no admin yet" unless admin

    session = ApiSession.generate!(user: admin, device: "recovery link", expires_at: 1.day.from_now)
    code = session.issue_handoff!(ttl: 10.minutes)
    origin = GlassHost.origin || "http://localhost:3004"
    Activity.record(source: "auth", event: "recovery_link", severity: Activity::Severity::Warn,
      summary: "A recovery sign-in link was minted for #{admin.email} from the console", subject: admin,
      household_id: admin.household_id)
    puts "#{origin}/auth/complete##{URI.encode_www_form('handoff' => code, 'return_to' => '/')}"
  end
end
