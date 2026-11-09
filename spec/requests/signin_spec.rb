# typed: false
# frozen_string_literal: true

require "rails_helper"
require "rake"

# Sign in with fog (fog's docs/signin-contract.md). The protocol is the
# vendored fog-client's, tested there against tokens fog signed; these specs
# hold Glass's half: what a verified identity does to Glass's accounts and
# sessions, and when Glass stops offering its own sign-in.
RSpec.describe "Sign in with fog", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:issuer) { "https://fog.example.test" }
  let(:oidc_env) do
    ENV.to_h.merge("OIDC_ISSUER" => issuer, "OIDC_CLIENT_ID" => "glass", "OIDC_CLIENT_SECRET" => "s3cret")
  end
  let(:binding_cookie) { "browser-binding" }

  def identity(subject: "person:H/KIM", role: "member", handle: "kim", sid: "sid-1")
    FogClient::Signin::Identity.new(issuer: issuer, subject: subject, handle: handle, name: handle.capitalize,
                                    roles: [ role ], sid: sid, amr: [ "pop", "user" ])
  end

  # A provider that vouches for the address: still never a way in.
  def with_email(id, email, verified: true)
    id.email = email
    id.email_verified = verified
    id
  end

  # The provider answers through the shared flow; stand it in.
  def returns(id, return_to: "/traces")
    allow_any_instance_of(FogClient::Signin::Flow).to receive(:finish).and_return([ id, return_to ])
  end

  def fragment(location)
    URI.decode_www_form(URI(location).fragment.to_s).to_h
  end

  # The browser keeps what the callback sets. A pending link is bound to it
  # by __Host-fog_link, which is Secure, and rack-test keeps Secure cookies
  # off plain http, so carry it the way the browser would.
  def callback!
    cookies[FogClient::Signin::Rails::COOKIE] = binding_cookie
    get "/auth/oidc/callback", params: { code: "c", state: "s" }
    @link_cookie = Array(response.headers["Set-Cookie"]).join("\n")[/#{FogClient::Signin::Rails::LINK_COOKIE}=([^;\s]+)/, 1]
    cookies[FogClient::Signin::Rails::LINK_COOKIE] = @link_cookie if @link_cookie
  end

  def handoff!(code)
    post "/api/v1/handoff", params: { handoff: code }
  end

  def signed_in_via_fog!(id)
    returns(id)
    callback!
    expect(response.location).to start_with("http://www.example.com/auth/complete#")
    handoff!(fragment(response.location)["handoff"])
    expect(response).to have_http_status(:created)
    json
  end

  before do
    stub_const("ENV", oidc_env)
    FogSignin.reset_attempts!
  end

  it "is not there off any provider" do
    stub_const("ENV", ENV.to_h.except("OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET"))
    get "/auth/oidc/start"
    expect(response).to have_http_status(:not_found)
    get "/api/v1/setup"
    expect(json["signin"]).to eq("enabled" => false, "fog_only" => false)
  end

  it "is routed to the kit, not to the console's shell" do
    stub_const("ENV", ENV.to_h.except("OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET"))
    get "/auth/oidc/callback"
    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
  end

  it "starts by sending the browser to the provider, bound to it by a cookie" do
    start = FogClient::Signin::Flow::Start.new(url: "#{issuer}/oauth2/authorize?client_id=glass&request_uri=x", binding: "b")
    allow_any_instance_of(FogClient::Signin::Flow).to receive(:start) do |_, **kw|
      expect(kw[:return_to]).to eq("/")
      start
    end
    get "/auth/oidc/start", params: { return_to: "//evil.example/" }
    expect(response).to redirect_to(start.url)
    expect(response.headers["Set-Cookie"]).to include("__Host-fog_signin=b").and include("secure").and include("httponly")
  end

  it "sends a callback that does not verify back to the sign-in page, saying so" do
    callback!
    expect(response).to redirect_to("http://www.example.com/login#signin_error=failed")
    expect(User.count).to eq(0)
  end

  it "says when the person or fog said no" do
    allow_any_instance_of(FogClient::Signin::Flow).to receive(:finish)
      .and_raise(FogClient::Signin::Denied.new("access_denied"))
    callback!
    expect(response).to redirect_to("http://www.example.com/login#signin_error=access_denied")
    expect(User.count).to eq(0)
  end

  it "makes the first person on a fresh Glass its admin: fog's sign-in is the setup wizard" do
    returns(identity(role: "admin", handle: "matthew", subject: "person:H/MATTHEW"))
    callback!
    expect(fragment(response.location)["return_to"]).to eq("/traces")
    handoff!(fragment(response.location)["handoff"])
    expect(response).to have_http_status(:created)
    user = User.find(json.dig("user", "id"))
    expect(user).to be_admin
    expect(user.identities.pluck(:issuer, :subject)).to eq([ [ issuer, "person:H/MATTHEW" ] ])
    expect(user.email).to match(/\Amatthew\.[0-9a-f]{12}@fog\.invalid\z/)
    expect(Household.count).to eq(1)

    # Usable straight away: the token reads the console.
    get "/api/v1/me", headers: bearer(json["token"])
    expect(response).to have_http_status(:ok)
  end

  it "keeps an address the provider vouches for, when no account holds it" do
    returns(with_email(identity(role: "admin"), "Kim@Home.test"))
    callback!
    handoff!(fragment(response.location)["handoff"])
    expect(User.find(json.dig("user", "id")).email).to eq("kim@home.test")
  end

  it "does not take an address the provider does not vouch for" do
    returns(with_email(identity(role: "admin"), "kim@home.test", verified: false))
    callback!
    handoff!(fragment(response.location)["handoff"])
    expect(User.find(json.dig("user", "id")).email).to end_with("@fog.invalid")
  end

  it "does not make a fresh Glass's first account from someone fog did not make its admin" do
    returns(identity(role: "member"))
    callback!
    handoff!(fragment(response.location)["handoff"])
    expect(User.find(json.dig("user", "id")).role).to eq("member")
  end

  context "with accounts already in Glass" do
    let(:household) { create_household }
    let!(:kim) { create_user(household: household, email: "kim@example.com", password: "passwordpassword") }

    it "never links by email: an unlinked identity is asked to prove an account is theirs" do
      returns(with_email(identity, "kim@example.com"))
      callback!
      expect(response.location).to start_with("http://www.example.com/auth/link#")
      expect(Identity.count).to eq(0)
      expect(ApiSession.count).to eq(0)
    end

    it "links an account once its owner signs in to it, then signs in by identity" do
      returns(identity)
      callback!
      pending = fragment(response.location)["pending"]
      post "/auth/oidc/link", params: { pending: pending, login: "kim@example.com", password: "wrong-password" }
      expect(response).to have_http_status(:unauthorized)
      expect(Identity.count).to eq(0)
      post "/auth/oidc/link", params: { pending: pending, login: "kim@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:ok)
      expect(json["return_to"]).to eq("/traces")
      handoff!(json["handoff"])
      expect(json.dig("user", "id")).to eq(kim.id)

      callback!
      expect(response.location).to start_with("http://www.example.com/auth/complete#")
    end

    it "refuses to link an identity twice" do
      returns(identity)
      callback!
      pending = fragment(response.location)["pending"]
      post "/auth/oidc/link", params: { pending: pending, fresh: "true" }
      cookies[FogClient::Signin::Rails::LINK_COOKIE] = @link_cookie # the same browser, replaying it
      post "/auth/oidc/link", params: { pending: pending, login: "kim@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:conflict)
      expect(kim.identities).to be_empty
    end

    it "starts a fresh account when the person asks, without taking anyone's address" do
      returns(with_email(identity, "kim@example.com"))
      callback!
      post "/auth/oidc/link", params: { pending: fragment(response.location)["pending"], fresh: "true" }
      handoff!(json["handoff"])
      fresh = User.find(json.dig("user", "id"))
      expect(fresh.id).not_to eq(kim.id)
      expect(fresh.household_id).to eq(household.id)
      # Kim's address is taken, and an address never identifies anyone: the
      # new account gets a stand-in rather than failing or sharing it.
      expect(fresh.email).to end_with("@fog.invalid")
      expect(User.count).to eq(2)
    end

    it "gives an identity made again after unlinking an address of its own" do
      returns(identity)
      callback!
      post "/auth/oidc/link", params: { pending: fragment(response.location)["pending"], fresh: "true" }
      first = Identity.sole.user
      Identity.delete_all

      callback!
      post "/auth/oidc/link", params: { pending: fragment(response.location)["pending"], fresh: "true" }
      expect(response).to have_http_status(:ok)
      second = Identity.sole.user
      expect(second.id).not_to eq(first.id)
      expect(second.email).to end_with("@fog.invalid")
      expect(second.email).not_to eq(first.email)
    end

    it "takes the role fog decided, every sign-in, and only a role Glass knows" do
      Identity.create!(user: kim, issuer: issuer, subject: "person:H/KIM")
      returns(identity(role: "admin"))
      callback!
      expect(kim.reload).to be_admin
      returns(identity(role: "guest"))
      callback!
      expect(kim.reload).to be_guest
      returns(identity(role: "superuser"))
      callback!
      expect(kim.reload.role).to eq("guest")
    end

    it "links nothing from a browser other than the one fog sent back" do
      returns(identity)
      callback!
      pending = fragment(response.location)["pending"]
      expect(response.headers["Set-Cookie"].to_s).to include("__Host-fog_link=").and include("samesite=strict")

      cookies.delete(FogClient::Signin::Rails::LINK_COOKIE)
      post "/auth/oidc/link", params: { pending: pending, login: "kim@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:unprocessable_content)
      cookies[FogClient::Signin::Rails::LINK_COOKIE] = "another-browser"
      post "/auth/oidc/link", params: { pending: pending, fresh: "true" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(Identity.count).to eq(0)
      expect(User.count).to eq(1)
    end

    it "refuses a visitor from a paired household: Glass hosts none" do
      returns(identity(subject: "person:OTHER/DAVE", handle: "dave").tap { |i| i.visitor = true; i.home = "OTHER" })
      callback!
      expect(fragment(response.location)).to eq("signin_error" => "visitors_not_hosted")
      expect(Identity.count).to eq(0)
      expect(User.count).to eq(1)
    end

    it "refuses a pending link that was tampered with" do
      post "/auth/oidc/link", params: { pending: "not-sealed", fresh: "true" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(User.count).to eq(1)
    end
  end

  describe "handoff" do
    it "is good once" do
      returns(identity(role: "admin"))
      callback!
      code = fragment(response.location)["handoff"]
      handoff!(code)
      expect(response).to have_http_status(:created)
      handoff!(code)
      expect(response).to have_http_status(:unauthorized)
    end

    it "is good for a minute" do
      returns(identity(role: "admin"))
      callback!
      code = fragment(response.location)["handoff"]
      travel 2.minutes do
        handoff!(code)
      end
      expect(response).to have_http_status(:unauthorized)
    end

    it "gives a fog session a lifetime and the provider's sid" do
      body = signed_in_via_fog!(identity(role: "admin", sid: "sid-9"))
      session = ApiSession.live(body["token"])
      expect(session.oidc_sid).to eq("sid-9")
      expect(session.device).to eq("fog")
      expect(session.expires_at).to be_within(1.minute).of(ApiSession::FOG_TTL.from_now)
    end
  end

  describe "back-channel logout" do
    let(:household) { create_household }
    let(:kim) { create_user(household: household) }

    def logout!(subject: nil, sid: nil)
      allow_any_instance_of(FogClient::Signin::Backchannel).to receive(:verify)
        .and_return(FogClient::Signin::Backchannel::Logout.new(subject: subject, sid: sid, jti: "j"))
      post "/auth/oidc/backchannel", params: { logout_token: "t" }
    end

    it "ends exactly the sessions the provider names" do
      Identity.create!(user: kim, issuer: issuer, subject: "person:H/KIM")
      fog = ApiSession.generate!(user: kim, oidc_sid: "sid-1", expires_at: 30.days.from_now)
      other = ApiSession.generate!(user: kim, oidc_sid: "sid-2", expires_at: 30.days.from_now)
      logout!(sid: "sid-1")
      expect(response).to have_http_status(:ok)
      expect(ApiSession.exists?(fog.id)).to be(false)
      expect(ApiSession.exists?(other.id)).to be(true)
    end

    it "ends every session of a person fog removed, and only theirs at this provider" do
      Identity.create!(user: kim, issuer: issuer, subject: "person:H/KIM")
      elsewhere = create_user(household: household)
      Identity.create!(user: elsewhere, issuer: "https://other.example", subject: "person:H/KIM")
      kims = [ ApiSession.generate!(user: kim, oidc_sid: "sid-1"), ApiSession.generate!(user: kim, device: "laptop") ]
      theirs = ApiSession.generate!(user: elsewhere)
      logout!(subject: "person:H/KIM")
      expect(response).to have_http_status(:ok)
      expect(ApiSession.where(id: kims.map(&:id))).to be_empty
      expect(ApiSession.exists?(theirs.id)).to be(true)
    end

    it "leaves API tokens alone: agents and integrations are not signed in by fog" do
      Identity.create!(user: kim, issuer: issuer, subject: "person:H/KIM")
      token = ApiToken.generate(user: kim, name: "script").record
      logout!(subject: "person:H/KIM")
      expect(ApiToken.exists?(token.id)).to be(true)
    end

    it "refuses a token that does not verify" do
      allow_any_instance_of(FogClient::Signin::Backchannel).to receive(:verify).and_raise(FogClient::Signin::Invalid, "bad")
      post "/auth/oidc/backchannel", params: { logout_token: "t" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "lets an expired fog session go" do
    user = create_user(household: create_household)
    session = ApiSession.generate!(user: user, oidc_sid: "s", expires_at: 1.minute.ago)
    get "/api/v1/me", headers: bearer(session.token)
    expect(response).to have_http_status(:unauthorized)
    expect(ApiSession.exists?(session.id)).to be(false)
  end

  describe "fog only" do
    let(:on_fog) { oidc_env.merge("FOG_API_URL" => "http://fog.test", "FOG_API_TOKEN" => "apptok") }
    let(:household) { create_household }
    let!(:user) { create_user(household: household, email: "m@example.com", role: "admin") }

    it "turns local sign-in off once Glass has proven it runs on fog" do
      stub_const("ENV", on_fog)
      allow(FogClient::Signin::Proof).to receive(:check).and_return(false)
      get "/api/v1/setup"
      expect(json["signin"]).to eq("enabled" => true, "fog_only" => false)
      post "/api/v1/session", params: { email: "m@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:created)

      allow(FogClient::Signin::Proof).to receive(:check).and_return(true)
      travel FogSignin::RETRY_EVERY + 1.second do
        get "/api/v1/setup"
      end
      expect(json["signin"]).to eq("enabled" => true, "fog_only" => true)
      expect(ActivityEntry.where(source: "auth", event: "fog_only")).to exist
      post "/api/v1/session", params: { email: "m@example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:forbidden)
    end

    it "asks fog at most once per interval until it has been proven" do
      stub_const("ENV", on_fog)
      allow(FogClient::Signin::Proof).to receive(:check).and_return(false)
      3.times { get "/api/v1/setup" }
      expect(FogClient::Signin::Proof).to have_received(:check).once
    end

    it "never asks off fog, or with fog sign-in off" do
      allow(FogClient::Signin::Proof).to receive(:check).and_return(true)
      get "/api/v1/setup"
      stub_const("ENV", on_fog.except("OIDC_ISSUER"))
      get "/api/v1/setup"
      expect(FogClient::Signin::Proof).not_to have_received(:check)
      expect(json["signin"]).to eq("enabled" => false, "fog_only" => false)
    end

    context "once proven" do
      before do
        AppSetting.current.update!(fog_attested_at: 1.day.ago)
        stub_const("ENV", on_fog)
      end

      it "refuses every other door: passwords, passkeys, invites" do
        post "/api/v1/session", params: { email: "m@example.com", password: "passwordpassword" }
        expect(response).to have_http_status(:forbidden)
        post "/api/v1/auth/passkey/login/begin"
        expect(response).to have_http_status(:forbidden)
        post "/api/v1/auth/passkey/login/finish", params: { credential: {}, challenge_token: "x" }
        expect(response).to have_http_status(:forbidden)

        invite = InviteCode.generate!(household: household, created_by: user, role: User::Role::Member)
        post "/api/v1/invites/accept", params: { code: invite.code, name: "N", email: "n@example.com", password: "passwordpassword" }
        expect(response).to have_http_status(:forbidden)
        expect(User.count).to eq(1)
        expect(invite.reload).to be_usable
      end

      it "turns the setup wizard off, restore included: the first person through fog is the admin" do
        User.delete_all
        get "/api/v1/setup"
        expect(json["setup_required"]).to be(false)
        post "/api/v1/setup", params: { household_name: "H", email: "a@example.com", name: "A", password: "passwordpassword" }
        expect(response).to have_http_status(:forbidden)
        post "/api/v1/setup/restore"
        expect(response).to have_http_status(:forbidden)
        expect(User.count).to eq(0)
      end

      it "still signs people in through fog, and keeps API tokens working" do
        generated = ApiToken.generate(user: user, name: "script")
        get "/api/v1/me", headers: bearer(generated.token)
        expect(response).to have_http_status(:ok)
        expect(generated.record.reload.last_used_at).to be_present

        Identity.create!(user: user, issuer: issuer, subject: "person:H/M")
        body = signed_in_via_fog!(identity(subject: "person:H/M", role: "admin"))
        expect(body.dig("user", "id")).to eq(user.id)
      end

      it "stays fog-only when fog cannot be reached, and ends when Glass leaves fog" do
        allow(FogClient::Signin::Proof).to receive(:check).and_return(false)
        get "/api/v1/setup"
        expect(json.dig("signin", "fog_only")).to be(true)
        expect(FogClient::Signin::Proof).not_to have_received(:check)

        stub_const("ENV", oidc_env.except("FOG_API_URL"))
        get "/api/v1/setup"
        expect(json.dig("signin", "fog_only")).to be(false)
        post "/api/v1/session", params: { email: "m@example.com", password: "passwordpassword" }
        expect(response).to have_http_status(:created)
      end
    end
  end

  it "mints a recovery link from the console that signs the admin in once" do
    admin = create_user(household: create_household, role: "admin")
    Rails.application.load_tasks unless Rake::Task.task_defined?("glass:recovery_link")
    task = Rake::Task["glass:recovery_link"]
    task.reenable
    out = capture_stdout { task.invoke }
    code = fragment(out.strip)["handoff"]
    handoff!(code)
    expect(response).to have_http_status(:created)
    expect(json.dig("user", "id")).to eq(admin.id)
    handoff!(code)
    expect(response).to have_http_status(:unauthorized)
    expect(ActivityEntry.where(source: "auth", event: "recovery_link", household_id: admin.household_id)).to exist
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end
