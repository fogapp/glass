# typed: strict
# frozen_string_literal: true

Rails.application.routes.draw do
  # Health endpoint for fog's swap gate + monitor: unauthenticated, <500 = ok.
  get "up" => "rails/health#show", as: :rails_health_check

  # glass-ingest/1 (docs/ingest-protocol.md): where agents report. Outside
  # /api on purpose — it is authenticated by an ingest key, never by a
  # console session, and shares nothing with the bearer stack.
  post "ingest/v1/batch" => "ingest#batch", as: :ingest_batch

  # Sign in with fog (fog's docs/signin-contract.md): plain OpenID Connect,
  # so any provider OIDC_ISSUER names works the same way. The console's
  # people only — agents and integrations keep their keys and tokens.
  scope "auth/oidc", controller: "auth/oidc" do
    get "start", action: :start, as: :oidc_start
    get "callback", action: :callback, as: :oidc_callback
    post "backchannel", action: :backchannel, as: :oidc_backchannel
    post "link", action: :link, as: :oidc_link
  end

  namespace :api do
    namespace :v1 do
      resource :setup, only: %i[show create], controller: "setup" do
        # Restore-from-backup: the wizard's alternative to creating a fresh
        # household (fog-backup/2).
        post :restore
      end
      resource :session, only: %i[create destroy]
      # The console trades a fog sign-in's one-time code for its session.
      resource :handoff, only: :create
      # Passkeys (WebAuthn): sign in, and manage the signed-in user's credentials.
      namespace :auth do
        post "passkey/login/begin" => "passkeys#login_begin"
        post "passkey/login/finish" => "passkeys#login_finish"
      end
      resources :webauthn_credentials, only: %i[index destroy] do
        collection do
          post "register/begin" => "webauthn_credentials#register_begin"
          post "register/finish" => "webauthn_credentials#register_finish"
        end
      end
      resources :invites, only: :create do
        post :accept, on: :collection
      end
      get "me" => "users#me"
      resources :users, only: :index
      resources :api_tokens, only: %i[index create destroy]

      # The things that report, and the keys they report with.
      resources :apps, only: %i[index show create update destroy] do
        resources :ingest_keys, only: %i[index create destroy]
      end

      # The one read path over telemetry: every chart, table
      # and list in the console is a query posted here.
      post "query" => "queries#run"
      get "query/sources" => "queries#sources"
      get "query/values" => "queries#values"
      get "markers" => "markers#index"

      # Flamegraphs: the merged call tree for a filter and a range.
      post "profiles/flamegraph" => "profiles#flamegraph"

      # One trace: its transactions across apps, and its kept spans.
      get "traces/:trace_id" => "traces#show", as: :trace

      # Saved questions: dashboards of them, and monitors with a condition.
      resources :dashboards, only: %i[index show create update destroy] do
        post :widgets, on: :member, action: :add_widget
      end
      resources :monitors, only: %i[index show create update destroy] do
        post :evaluate, on: :member
      end
      resources :incidents, only: :index

      # Paths through an app: pageview → pageview transitions.
      get "visitors/journeys" => "visitors#journeys"

      # What needs attention across the fleet, and one finding worked up.
      # A finding's id is its subject, base64url-encoded.
      get "triage" => "triage#index"
      get "triage/:id" => "triage#show", as: :triage_finding, constraints: { id: /[A-Za-z0-9_-]+/ }
      # A person's answer to a finding: dismissed until it gets worse, or
      # ignored for good; deleting it puts the finding back.
      put "triage/:id/dismissal" => "triage#dismiss", as: :triage_dismissal, constraints: { id: /[A-Za-z0-9_-]+/ }
      delete "triage/:id/dismissal" => "triage#restore", constraints: { id: /[A-Za-z0-9_-]+/ }

      # Every reporting process, and the console's status line.
      get "fleet" => "fleet#index"
      get "status" => "status#show"

      # Settings.
      resource :app_setting, only: %i[show update], controller: "app_settings" do
        post :test_ntfy
        post :test_fog
      end
      get "storage" => "storage#show"

      get "background_jobs" => "background_jobs#index"
      post "background_jobs/:key/run" => "background_jobs#run", as: :run_background_job

      # "events", not "activity": EasyPrivacy-class blocklists kill any
      # request matching */activity, so with an ad blocker installed the
      # Activity page rendered as a permanent error. The controller keeps
      # its name; only the URL is camouflage.
      get "events" => "activity#index"
      resource :about, only: :show, controller: "about"
    end
  end

  # MCP surface: agents connect here with an ApiToken.
  # Stateless Streamable HTTP in JSON mode — POST carries the JSON-RPC
  # traffic; GET and DELETE reach the transport so it answers 405 per the
  # stateless spec instead of the SPA shell answering 200.
  match "mcp", to: "mcp#handle", via: %i[get post delete], as: :mcp

  # fog-backup/2 machine surface (fog's docs/backup-contract.md): fog drives
  # delegated backups and restores through here, authenticated by the
  # fog-injected FOG_API_TOKEN — never by console sessions.
  scope "fog", controller: :fog, defaults: { format: :json } do
    get "backup", action: :descriptor
    post "backup", action: :create_backup
    get "backup/jobs/:id", action: :job_status, as: :fog_backup_job
    get "backup/jobs/:id/artifact", action: :artifact, as: :fog_backup_artifact
    delete "backup/jobs/:id", action: :destroy_job
    post "restore", action: :restore, as: :fog_restore
  end

  # fog-integration/1 (fog's docs/integrations-contract.md): fog mints and
  # revokes another app's Glass credential when the operator connects it.
  scope "fog", defaults: { format: :json } do
    resources :integrations, controller: :fog_integrations, only: %i[create show destroy], as: :fog_integrations
  end

  # Console SPA fallback — every non-API, non-asset path renders the shell so
  # client-side routes survive a refresh.
  get "*path" => "spa#show", constraints: ->(req) {
    !req.path.start_with?("/api", "/up", "/assets", "/rails", "/fog", "/ingest", "/mcp", "/_glass", "/auth/oidc")
  }
  root "spa#show"
end
