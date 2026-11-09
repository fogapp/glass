# typed: strict
# frozen_string_literal: true

# Where people reach Glass: the host fog serves it on (GLASS_HOST, injected
# as `{{fqdn}}` by glass.fog.yaml). It is the WebAuthn relying party every
# passkey is bound to, the identity a backup records, and the origin of every
# link Glass hands out. Absent off fog, and then there is no link to give.
module GlassHost
  extend T::Sig

  sig { returns(T.nilable(String)) }
  def self.host = ENV["GLASS_HOST"].presence

  # fog terminates TLS, so the public origin is always https.
  sig { returns(T.nilable(String)) }
  def self.origin
    current = host
    current && "https://#{current}"
  end
end
