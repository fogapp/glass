# typed: strict
# frozen_string_literal: true

module InviteSerializer
  extend T::Sig

  sig { params(invite: InviteCode).returns(T::Hash[Symbol, T.untyped]) }
  def self.invite_json(invite)
    { code: invite.code, role: invite.role, expires_at: invite.expires_at }
  end
end
