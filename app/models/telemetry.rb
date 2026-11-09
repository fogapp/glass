# typed: strict
# frozen_string_literal: true

# The signals' namespace (the `telemetry` database: app/models/telemetry/).
module Telemetry
  extend T::Sig

  # How a request reached the box: the `origin` of a unit of work, of a
  # browser event and of the visit it belongs to.
  ORIGINS = T.let(%w[lan vpn tunnel public].freeze, T::Array[String])

  # Sorbet cannot read a literal past 2**62, so this is computed.
  TWO_64 = T.let(T.unsafe(2)**64, Integer)

  # A span id column (a signed bigint: 64 bits of hex, two's complement,
  # as Ingest::Coerce.span_id stores it) as the hex the agent sent.
  sig { params(value: Integer).returns(String) }
  def self.span_hex(value) = format("%016x", value.negative? ? value + TWO_64 : value)

  # A dictionary row's identity: the first 63 bits of the SHA-256 of what
  # names it — a bigint, never negative. Series tag sets, profile functions
  # and stacks are all keyed this way; the values are in their unique
  # indexes, so this must never change.
  sig { params(bytes: String).returns(Integer) }
  def self.digest63(bytes)
    T.cast(Digest::SHA256.digest(bytes).unpack1("Q>"), Integer) & 0x7fff_ffff_ffff_ffff
  end
end
