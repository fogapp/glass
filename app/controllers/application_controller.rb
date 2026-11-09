# typed: strict
# frozen_string_literal: true

# Authenticated surface base. Public endpoints (health, the SPA shell, the
# /fog/* contract surface) deliberately do NOT inherit from this — they sit
# outside the bearer-token stack.
#
# Two credential kinds resolve to a User: an ApiSession (interactive login)
# or a user-minted ApiToken (`glass_` prefix — integrations, MCP). A
# read-scoped token may only read; a non-GET route it may reach (running a
# query is a POST) is one its controller opens with `allow_read_scope`.
#
# Ingest keys (`glass_ing_`, IngestKey) are a third credential and never
# authenticate here: they can report for one app and read nothing
# (IngestController).
class ApplicationController < ActionController::API
  extend T::Sig

  include BearerToken
  include ErrorEnvelope

  before_action :set_trace_id
  before_action :require_auth
  before_action :deny_read_scope_writes

  private

  sig { void }
  def set_trace_id
    Current.trace_id = request.request_id
  end

  sig { void }
  def require_auth
    token = bearer_token
    api_token = ApiToken.authenticate(token)
    if api_token
      api_token.record_use!
      user = T.cast(api_token.user, User)
      Current.user = user
      Current.household = user.household
      Current.api_token = api_token
      return
    end

    session = current_api_session
    return render_errors("unauthorized", status: :unauthorized) if session.nil?

    user = T.cast(session.user, User)
    Current.user = user
    Current.household = user.household
    Current.api_session = session
    session.record_use!
  end

  # Read tokens are for looking: every non-GET action is closed to them
  # unless the controller opens it with `allow_read_scope`.
  sig { void }
  def deny_read_scope_writes
    token = Current.api_token
    return unless token.is_a?(ApiToken) && token.read_only?
    return if request.get? || request.head?
    return if self.class.read_scope_actions.include?(action_name.to_s)

    render_errors("This token is read-only", status: :forbidden)
  end

  class_attribute :read_scope_actions, instance_accessor: false, default: T.let([].freeze, T::Array[String])

  sig { params(actions: Symbol).void }
  def self.allow_read_scope(*actions)
    self.read_scope_actions = (read_scope_actions + actions.map(&:to_s)).freeze
  end

  sig { returns(T.nilable(ApiSession)) }
  def current_api_session
    @current_api_session = T.let(@current_api_session, T.nilable(ApiSession))
    return @current_api_session if @looked_up_session

    @looked_up_session = T.let(true, T.nilable(T::Boolean))
    token = bearer_token
    @current_api_session = token.present? && !token.start_with?(ApiToken::PREFIX) ? ApiSession.live(token) : nil
  end

  # The typed boundary over CurrentAttributes' untyped accessors — call these
  # rather than Current.user/.household so the rest of app/ stays typed.
  # Private like every helper here: a `finds` block runs on the controller,
  # so it calls them with an implicit receiver.
  sig { returns(User) }
  def current_user! = T.cast(Current.user, User)

  sig { returns(Household) }
  def current_household! = T.cast(Current.household, Household)
end
