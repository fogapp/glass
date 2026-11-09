# typed: strict
# frozen_string_literal: true

# What fog sign-in means for Glass's own accounts
# (fog's docs/signin-contract.md): FogClient::Signin::Rails asks, this
# answers in Glass's models. Glass keeps its users, its sessions and its
# roles (User::Role: admin, member, guest); fog proves who someone
# is. Only the console's people sign in this way: agents report with ingest
# keys and integrations read with API tokens, and neither is touched.
class SigninAdapter
  extend T::Sig

  ADMIN_ROLE = T.let(User::Role::Admin.serialize, String)

  sig { returns(String) }
  def admin_role = ADMIN_ROLE

  sig { params(issuer: String, subject: String).returns(T.nilable(User)) }
  def find_by_identity(issuer, subject)
    Identity.find_by(issuer: issuer, subject: subject)&.user
  end

  # SCIM-provisioned accounts carry the subject before anyone signs in
  # (fog's docs/signin-contract.md); until Glass takes SCIM there are none.
  sig { params(subject: String).returns(T.nilable(User)) }
  def find_by_external_id(subject) = nil

  sig { returns(Integer) }
  def account_count = User.count

  # The first sign-in on a fresh Glass is the setup wizard: the household and
  # its admin, named for the person fog says this is.
  sig { params(identity: FogClient::Signin::Identity).returns(User) }
  def bootstrap!(identity)
    ActiveRecord::Base.transaction do
      household = Household.create!(name: "Home")
      create_user(household, identity, ADMIN_ROLE)
    end
  end

  # Someone new joins the household an invite would have put them in: the
  # one this Glass was set up with.
  sig { params(identity: FogClient::Signin::Identity).returns(User) }
  def provision!(identity)
    household = Household.instance || Household.create!(name: "Home")
    create_user(household, identity, role_for(identity))
  end

  sig { params(user: User, identity: FogClient::Signin::Identity).void }
  def link!(user, identity)
    Identity.create!(user: user, issuer: identity.issuer, subject: identity.subject)
    Activity.record(source: "auth", event: "identity.linked", subject: user, household_id: user.household_id,
      summary: "#{user.name}'s account now signs in with #{identity.handle.presence || 'fog'}")
  end

  # The link page's proof that an existing account is theirs: the same email
  # and password sign-in takes. The email finds the account the person
  # named; it is never how a fog identity finds one.
  sig { params(login: String, password: String).returns(T.nilable(User)) }
  def authenticate_local(login, password)
    user = User.find_by(email: login.strip.downcase)
    user if user&.authenticate(password)
  end

  # fog decided the role; Glass only refuses one it does not know.
  sig { params(user: User, role: String).void }
  def apply_role!(user, role)
    return unless User::Role.has_serialized?(role)
    return if user.role == role

    user.update!(role: role)
  end

  sig { params(user: User, identity: FogClient::Signin::Identity).returns(String) }
  def start_session!(user, identity)
    session = ApiSession.generate!(user: user, device: "fog", oidc_sid: identity.sid, expires_at: ApiSession::FOG_TTL.from_now)
    Activity.record(source: "auth", event: "fog.signed_in", summary: "#{user.name} signed in with fog",
      subject: user, household_id: user.household_id)
    session.issue_handoff!
  end

  # Back-channel logout: a sid ends exactly the sessions it started; a
  # subject alone (the person was suspended or removed) ends every session
  # of the accounts linked to it at this provider — never an identity some
  # other issuer vouched for under the same subject.
  sig { params(sid: T.nilable(String), subject: T.nilable(String)).returns(Integer) }
  def end_sessions!(sid:, subject:)
    if sid.present?
      ApiSession.where(oidc_sid: sid).destroy_all.size
    elsif subject.present?
      issuer = FogClient::Signin.config&.issuer
      return 0 if issuer.nil?

      user_ids = Identity.where(issuer: issuer, subject: subject).select(:user_id)
      ApiSession.where(user_id: user_ids).destroy_all.size
    else
      0
    end
  end

  private

  sig { params(identity: FogClient::Signin::Identity).returns(String) }
  def role_for(identity)
    (User::Role.try_deserialize(identity.role.to_s) || User::Role::Member).serialize
  end

  sig { params(household: Household, identity: FogClient::Signin::Identity, role: String).returns(User) }
  def create_user(household, identity, role)
    User.register!(household: household, email: email_for(identity),
      name: identity.name.presence || identity.handle.presence || "Someone",
      password: SecureRandom.urlsafe_base64(32), role: User::Role.deserialize(role))
  end

  # Glass's accounts need an address; a fog person may have none, and fog
  # does not verify the ones it has. So the account takes one only
  # when the provider vouches for it and no account already holds it, and
  # otherwise a stand-in under .invalid (RFC 2606), which can never deliver
  # or collide with a real address — built from a digest of the identity, so
  # any provider's subject makes a valid one. Either way it is display only,
  # and never used to find anyone.
  sig { params(identity: FogClient::Signin::Identity).returns(String) }
  def email_for(identity)
    given = identity.email.to_s.strip.downcase
    return given if identity.email_verified == true && given.match?(URI::MailTo::EMAIL_REGEXP) && !User.exists?(email: given)

    handle = identity.handle.to_s.downcase.gsub(/[^a-z0-9_-]/, "").first(32).presence || "person"
    stand_in = "#{handle}.#{Digest::SHA256.hexdigest("#{identity.issuer} #{identity.subject}").first(12)}@fog.invalid"
    # The same identity made an account before and was later unlinked from
    # it: that account keeps its address, and this one gets its own.
    User.exists?(email: stand_in) ? stand_in.sub("@", ".#{SecureRandom.hex(3)}@") : stand_in
  end
end
