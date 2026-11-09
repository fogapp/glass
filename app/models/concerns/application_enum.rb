# typed: strict
# frozen_string_literal: true

# Include in every T::Enum so wire format (as_json) and interpolation (to_s)
# emit the serialized string — code manipulates typed instances, storage and
# JSON stay plain strings.
module ApplicationEnum
  extend T::Sig
  extend T::Helpers

  requires_ancestor { T::Enum }

  sig { returns(String) }
  def to_s = serialize.to_s

  sig { params(_args: T.untyped).returns(String) }
  def as_json(*_args) = serialize.to_s
end
