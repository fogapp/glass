# typed: true

# The part of fog-client's core (lib/fog_client.rb) Glass reads: the fog API
# surface fog injects (FOG_API_URL, FOG_API_TOKEN). The sign-in kit's shim is
# fog_client_signin.rbi, copied from the gem.
module FogClient
  sig { returns(T.nilable(String)) }
  def self.url; end

  sig { returns(T.nilable(String)) }
  def self.token; end

  sig { returns(T::Boolean) }
  def self.available?; end
end
