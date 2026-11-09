# typed: strict
# frozen_string_literal: true

# Class-method serializers, no gem: every JSON shape for a
# record type lives here — never hand-build a payload inline for a type that
# has a serializer.
module UserSerializer
  extend T::Sig

  sig { params(user: User).returns(T::Hash[Symbol, T.untyped]) }
  def self.user_json(user)
    {
      id: user.id,
      email: user.email,
      name: user.name,
      role: user.role,
      household_id: user.household_id
    }
  end
end
