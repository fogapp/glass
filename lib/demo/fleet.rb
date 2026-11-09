# typed: false
# frozen_string_literal: true

module Demo
  # The pretend fleet `bin/rails glass:demo` reports for: five house apps
  # with plausible endpoints, jobs, latencies and call stacks, one
  # third-party image that carries no agent, and an agent harness
  # (Demo::Harness). Development and e2e only —
  # nothing here is loaded in a running app.
  #
  # Three stories are written into the data on purpose, because a console
  # that only ever shows flat lines cannot be judged:
  #
  #   - a bad deploy: hook's search got ~2.4× slower for six hours
  #     yesterday, until the next deploy fixed it. The flamegraph diff across
  #     those deploys points at one function.
  #   - an error burst: hub's calendar endpoint failed a third of the time
  #     for twenty minutes this morning.
  #   - an outage: minio's container was down for forty minutes last
  #     night, which only fog could have told Glass.
  module Fleet
    Endpoint = Struct.new(:name, :method, :route, :share, :median, :sigma, :db, :db_n, :view, :ext, :error_rate, :n1, :stack,
      keyword_init: true)
    Job = Struct.new(:name, :queue, :per_hour, :median, :sigma, :db, :error_rate, :stack, keyword_init: true)
    Spec = Struct.new(:slug, :name, :rps, :endpoints, :jobs, :processes, keyword_init: true)

    def self.endpoint(name, route, share:, median:, method: "GET", sigma: 0.55, db: 0.35, db_n: 4, view: 0.08, ext: 0.0,
      error_rate: 0.004, n1: false, stack: [])
      Endpoint.new(name: name, method: method, route: route, share: share, median: median, sigma: sigma, db: db, db_n: db_n,
        view: view, ext: ext, error_rate: error_rate, n1: n1, stack: stack)
    end

    def self.job(name, queue:, per_hour:, median:, sigma: 0.7, db: 0.3, error_rate: 0.01, stack: [])
      Job.new(name: name, queue: queue, per_hour: per_hour, median: median, sigma: sigma, db: db, error_rate: error_rate, stack: stack)
    end

    # A frame: [name, file, category]. The stacks below are the part of a
    # call tree under the controller action or the job's #perform — the
    # common Rack/Rails prefix is added by Profiles.
    AR_LOAD = [
      [ "ActiveRecord::Relation#load", "activerecord/lib/active_record/relation.rb", "gem" ],
      [ "ActiveRecord::Querying#_query_by_sql", "activerecord/lib/active_record/querying.rb", "gem" ],
      [ "ActiveRecord::ConnectionAdapters::PostgreSQL::DatabaseStatements#perform_query",
        "activerecord/lib/active_record/connection_adapters/postgresql/database_statements.rb", "gem" ],
      [ "PG::Connection#exec_params", "<cfunc>", "native" ]
    ].freeze
    AR_INSTANTIATE = [
      [ "ActiveRecord::Relation#load", "activerecord/lib/active_record/relation.rb", "gem" ],
      [ "ActiveRecord::Persistence::ClassMethods#instantiate_instance_of", "activerecord/lib/active_record/persistence.rb", "gem" ],
      [ "ActiveModel::AttributeSet::Builder#build_from_database", "activemodel/lib/active_model/attribute_set/builder.rb", "gem" ]
    ].freeze
    JSON_GEN = [
      [ "ActionController::Renderers.render_to_body", "actionpack/lib/action_controller/metal/renderers.rb", "gem" ],
      [ "ActiveSupport::JSON::Encoding::JSONGemEncoder#encode", "activesupport/lib/active_support/json/encoding.rb", "gem" ],
      [ "JSON::Ext::Generator::State#generate", "<cfunc>", "native" ]
    ].freeze
    NET_HTTP = [
      [ "UpstreamHttpClient#http_post_json", "app/services/upstream_http_client.rb", "app" ],
      [ "Net::HTTP#request", "net-http/lib/net/http.rb", "gem" ],
      [ "Net::BufferedIO#rbuf_fill", "net-protocol/lib/net/protocol.rb", "gem" ],
      [ "IO#wait_readable", "<cfunc>", "native" ]
    ].freeze

    def self.app(name, file) = [ name, file, "app" ]

    # [share of the transaction's time, state, frames under the action]
    def self.branch(share, state, *frames) = [ share, state, frames.flatten(1).each_slice(3).to_a ]

    HOOK = Spec.new(
      slug: "hook", name: "Hook", rps: 0.22, processes: { "web" => 1, "worker" => 1 },
      endpoints: [
        endpoint("Api::V1::WantsController#index", "/api/v1/wants", share: 0.28, median: 38, db: 0.45, db_n: 6,
          stack: [
            branch(0.34, "idle", *app("Want.joined_to_subjects", "app/models/want.rb"), *AR_LOAD),
            branch(0.16, "running", *app("Want.joined_to_subjects", "app/models/want.rb"), *AR_INSTANTIATE),
            branch(0.30, "running", *app("WantSerializer.want_json", "app/serializers/want_serializer.rb"),
              *app("SubjectCardSerializer.card", "app/serializers/subject_card_serializer.rb")),
            branch(0.14, "running", *JSON_GEN),
            branch(0.06, "stalled", *app("WantSerializer.want_json", "app/serializers/want_serializer.rb"))
          ]),
        endpoint("Api::V1::WantsController#show", "/api/v1/wants/:id", share: 0.2, median: 24, db: 0.5, db_n: 9, n1: true,
          stack: [
            branch(0.42, "idle", *app("Want#attempts", "app/models/want.rb"), *AR_LOAD),
            branch(0.38, "running", *app("AttemptSerializer.attempt_json", "app/serializers/attempt_serializer.rb")),
            branch(0.20, "running", *JSON_GEN)
          ]),
        endpoint("Api::V1::SearchController#index", "/api/v1/search", share: 0.12, median: 210, sigma: 0.7, db: 0.12, ext: 0.62,
          error_rate: 0.012,
          stack: [
            branch(0.58, "idle", *app("Catalog::Kind#search", "app/services/catalog/kind.rb"), *NET_HTTP),
            branch(0.22, "running", *app("Catalog::Kind#merge", "app/services/catalog/kind.rb"),
              *app("Text::Normalizer.fold", "app/services/text/normalizer.rb")),
            branch(0.12, "idle", *app("Catalog::Kind#existing", "app/services/catalog/kind.rb"), *AR_LOAD),
            branch(0.08, "running", *JSON_GEN)
          ]),
        endpoint("Api::V1::DashboardController#show", "/api/v1/dashboard", share: 0.18, median: 61, db: 0.6, db_n: 14,
          stack: [
            branch(0.55, "idle", *app("DashboardSerializer.dashboard_json", "app/serializers/dashboard_serializer.rb"), *AR_LOAD),
            branch(0.30, "running", *app("DashboardSerializer.dashboard_json", "app/serializers/dashboard_serializer.rb")),
            branch(0.15, "running", *JSON_GEN)
          ]),
        endpoint("Api::V1::ActivityController#index", "/api/v1/events", share: 0.12, median: 29, db: 0.55,
          stack: [
            branch(0.5, "idle", *app("ActivityEntrySerializer.preload", "app/serializers/activity_entry_serializer.rb"), *AR_LOAD),
            branch(0.5, "running", *app("ActivityEntrySerializer.entry_json", "app/serializers/activity_entry_serializer.rb"))
          ]),
        endpoint("Api::V1::WantsController#create", "/api/v1/wants", method: "POST", share: 0.04, median: 95, db: 0.5, db_n: 11,
          error_rate: 0.02,
          stack: [
            branch(0.6, "idle", *app("Wants::Transition.call", "app/services/wants/transition.rb"), *AR_LOAD),
            branch(0.4, "running", *app("Wants::Transition.call", "app/services/wants/transition.rb"))
          ]),
        endpoint("SpaController#show", "/*path", share: 0.06, median: 3, db: 0.0, db_n: 0, view: 0.6, error_rate: 0.0, stack: [
          branch(1.0, "running", [ "ActionView::Template#render", "actionview/lib/action_view/template.rb", "gem" ])
        ])
      ],
      jobs: [
        job("TrackOrdersJob", queue: "orders", per_hour: 120, median: 140, db: 0.2, stack: [
          branch(0.7, "idle", *app("Vendors::Client#orders", "app/services/vendors/client.rb"), *NET_HTTP),
          branch(0.3, "running", *app("Orders::Tracker#apply", "app/services/orders/tracker.rb"))
        ]),
        job("SearchPlanJob", queue: "search", per_hour: 14, median: 2_400, sigma: 0.9, db: 0.1, error_rate: 0.04, stack: [
          branch(0.62, "idle", *app("Sources::Feed#search", "app/services/sources/feed.rb"), *NET_HTTP),
          branch(0.24, "running", *app("Matching::Scorer#score", "app/services/matching/scorer.rb"),
            *app("Matching::TitleParser#parse", "app/services/matching/title_parser.rb")),
          branch(0.14, "running", [ "Nokogiri::XML::Document.parse", "<cfunc>", "native" ])
        ]),
        job("ImportItemJob", queue: "import", per_hour: 3, median: 5_800, sigma: 0.8, db: 0.08, stack: [
          branch(0.55, "running", *app("Imports::Verifier#verify", "app/services/imports/verifier.rb"),
            [ "Zip::File#read", "rubyzip/lib/zip/file.rb", "gem" ]),
          branch(0.45, "idle", *app("Storage::Writer#write", "app/services/storage/writer.rb"),
            [ "IO.copy_stream", "<cfunc>", "native" ])
        ]),
        job("SyncSourcesJob", queue: "search", per_hour: 16, median: 900, db: 0.2, stack: [
          branch(0.7, "idle", *app("Sources::Feed#poll", "app/services/sources/feed.rb"), *NET_HTTP),
          branch(0.3, "running", [ "Nokogiri::XML::Document.parse", "<cfunc>", "native" ])
        ])
      ]
    )

    HUB = Spec.new(
      slug: "hub", name: "Hub", rps: 0.35, processes: { "web" => 1 },
      endpoints: [
        endpoint("Api::V1::TodayController#show", "/api/v1/today", share: 0.3, median: 72, db: 0.5, db_n: 18, n1: true,
          stack: [
            branch(0.5, "idle", *app("TodaySerializer.today_json", "app/serializers/today_serializer.rb"), *AR_LOAD),
            branch(0.35, "running", *app("TodaySerializer.today_json", "app/serializers/today_serializer.rb")),
            branch(0.15, "running", *JSON_GEN)
          ]),
        endpoint("Api::V1::CalendarController#index", "/api/v1/calendar", share: 0.22, median: 110, db: 0.3, ext: 0.4,
          stack: [
            branch(0.45, "idle", *app("Calendar::Feed#events", "app/services/calendar/feed.rb"), *NET_HTTP),
            branch(0.35, "running", *app("Calendar::Feed#expand", "app/services/calendar/feed.rb"),
              [ "RRule::Rule#between", "rrule/lib/rrule/rule.rb", "gem" ]),
            branch(0.2, "idle", *AR_LOAD)
          ]),
        endpoint("Api::V1::PhotosController#index", "/api/v1/photos", share: 0.2, median: 46, db: 0.2, ext: 0.5, stack: [
          branch(0.6, "idle", *app("Photos::Client#timeline", "app/services/photos/client.rb"), *NET_HTTP),
          branch(0.4, "running", *app("PhotoSerializer.photo_json", "app/serializers/photo_serializer.rb"))
        ]),
        endpoint("Api::V1::TasksController#index", "/api/v1/tasks", share: 0.16, median: 22, db: 0.55, stack: [
          branch(0.6, "idle", *AR_LOAD), branch(0.4, "running", *app("TaskSerializer.task_json", "app/serializers/task_serializer.rb"))
        ]),
        endpoint("Api::V1::TasksController#update", "/api/v1/tasks/:id", method: "PATCH", share: 0.06, median: 31, db: 0.6, stack: [
          branch(1.0, "idle", *AR_LOAD)
        ]),
        endpoint("SpaController#show", "/*path", share: 0.06, median: 3, db: 0.0, db_n: 0, view: 0.6, error_rate: 0.0, stack: [
          branch(1.0, "running", [ "ActionView::Template#render", "actionview/lib/action_view/template.rb", "gem" ])
        ])
      ],
      jobs: [
        job("SyncCalendarsJob", queue: "default", per_hour: 12, median: 1_900, db: 0.2, stack: [
          branch(0.8, "idle", *app("Calendar::Feed#sync", "app/services/calendar/feed.rb"), *NET_HTTP),
          branch(0.2, "running", [ "Icalendar::Parser#parse", "icalendar/lib/icalendar/parser.rb", "gem" ])
        ]),
        job("FetchMailJob", queue: "default", per_hour: 30, median: 640, db: 0.15, error_rate: 0.03, stack: [
          branch(0.85, "idle", *app("Mail::Inbox#fetch", "app/services/mail/inbox.rb"), [ "Net::IMAP#fetch", "net-imap/lib/net/imap.rb", "gem" ]),
          branch(0.15, "running", [ "Mail::Message#parse", "mail/lib/mail/message.rb", "gem" ])
        ])
      ]
    )

    MANOR = Spec.new(
      slug: "manor", name: "Manor", rps: 0.12, processes: { "web" => 1, "worker" => 1 },
      endpoints: [
        endpoint("Api::V1::AccountsController#index", "/api/v1/accounts", share: 0.3, median: 44, db: 0.6, db_n: 7, stack: [
          branch(0.6, "idle", *AR_LOAD), branch(0.4, "running", *app("AccountSerializer.account_json", "app/serializers/account_serializer.rb"))
        ]),
        endpoint("Api::V1::TransactionsController#index", "/api/v1/transactions", share: 0.34, median: 88, db: 0.62, db_n: 9, stack: [
          branch(0.55, "idle", *app("Transaction.search", "app/models/transaction.rb"), *AR_LOAD),
          branch(0.25, "running", *app("Transaction.search", "app/models/transaction.rb"), *AR_INSTANTIATE),
          branch(0.2, "running", *JSON_GEN)
        ]),
        endpoint("Api::V1::ReportsController#cashflow", "/api/v1/reports/cashflow", share: 0.14, median: 320, sigma: 0.6, db: 0.78,
          db_n: 22, stack: [
            branch(0.74, "idle", *app("Reports::Cashflow#series", "app/services/reports/cashflow.rb"), *AR_LOAD),
            branch(0.26, "running", *app("Reports::Cashflow#bucket", "app/services/reports/cashflow.rb"))
          ]),
        endpoint("Api::V1::BudgetsController#show", "/api/v1/budgets/:id", share: 0.16, median: 57, db: 0.55, stack: [
          branch(0.6, "idle", *AR_LOAD), branch(0.4, "running", *app("BudgetSerializer.budget_json", "app/serializers/budget_serializer.rb"))
        ]),
        endpoint("SpaController#show", "/*path", share: 0.06, median: 3, db: 0.0, db_n: 0, view: 0.6, error_rate: 0.0, stack: [
          branch(1.0, "running", [ "ActionView::Template#render", "actionview/lib/action_view/template.rb", "gem" ])
        ])
      ],
      jobs: [
        job("SyncAccountsJob", queue: "default", per_hour: 6, median: 4_200, db: 0.3, error_rate: 0.05, stack: [
          branch(0.7, "idle", *app("Banking::Sync#pull", "app/services/banking/sync.rb"), *NET_HTTP),
          branch(0.3, "idle", *app("Banking::Sync#upsert", "app/services/banking/sync.rb"), *AR_LOAD)
        ]),
        job("ComputeMetricPointsJob", queue: "default", per_hour: 4, median: 7_500, db: 0.85, stack: [
          branch(0.85, "idle", *app("MetricPoint.recompute", "app/models/metric_point.rb"), *AR_LOAD),
          branch(0.15, "running", *app("MetricPoint.recompute", "app/models/metric_point.rb"))
        ])
      ]
    )

    STREAM = Spec.new(
      slug: "stream", name: "Stream", rps: 0.18, processes: { "web" => 1, "worker" => 1 },
      endpoints: [
        endpoint("Api::V1::LibraryController#index", "/api/v1/library", share: 0.3, median: 52, db: 0.5, db_n: 8, stack: [
          branch(0.55, "idle", *AR_LOAD), branch(0.45, "running", *app("TitleSerializer.card", "app/serializers/title_serializer.rb"))
        ]),
        endpoint("Api::V1::PlaybackController#show", "/api/v1/playback/:id", share: 0.24, median: 18, db: 0.45, stack: [
          branch(0.5, "idle", *AR_LOAD), branch(0.5, "running", *app("Playback::Session#manifest", "app/services/playback/session.rb"))
        ]),
        endpoint("Api::V1::PlaybackController#progress", "/api/v1/playback/:id/progress", method: "PUT", share: 0.34, median: 9,
          db: 0.7, db_n: 2, stack: [ branch(1.0, "idle", *AR_LOAD) ]),
        endpoint("Api::V1::SearchController#index", "/api/v1/search", share: 0.06, median: 64, db: 0.75, stack: [
          branch(0.8, "idle", *AR_LOAD), branch(0.2, "running", *JSON_GEN)
        ]),
        endpoint("SpaController#show", "/*path", share: 0.06, median: 3, db: 0.0, db_n: 0, view: 0.6, error_rate: 0.0, stack: [
          branch(1.0, "running", [ "ActionView::Template#render", "actionview/lib/action_view/template.rb", "gem" ])
        ])
      ],
      jobs: [
        job("TranscodeJob", queue: "transcode", per_hour: 2, median: 95_000, sigma: 0.5, db: 0.01, stack: [
          branch(0.97, "idle", *app("Transcode::Runner#run", "app/services/transcode/runner.rb"), [ "Process.wait", "<cfunc>", "native" ]),
          branch(0.03, "running", *app("Transcode::Runner#progress", "app/services/transcode/runner.rb"))
        ]),
        job("ScanLibraryJob", queue: "default", per_hour: 1, median: 12_000, db: 0.4, stack: [
          branch(0.5, "running", *app("Library::Scanner#walk", "app/services/library/scanner.rb"), [ "Dir.each_child", "<cfunc>", "native" ]),
          branch(0.5, "idle", *AR_LOAD)
        ])
      ]
    )

    FEED = Spec.new(
      slug: "feed", name: "Feed", rps: 0.09, processes: { "web" => 1, "worker" => 1 },
      endpoints: [
        endpoint("Api::V1::EntriesController#index", "/api/v1/entries", share: 0.62, median: 41, db: 0.55, db_n: 5, stack: [
          branch(0.55, "idle", *AR_LOAD), branch(0.45, "running", *app("EntrySerializer.entry_json", "app/serializers/entry_serializer.rb"))
        ]),
        endpoint("Api::V1::EntriesController#show", "/api/v1/entries/:id", share: 0.3, median: 16, db: 0.5, stack: [
          branch(0.5, "idle", *AR_LOAD), branch(0.5, "running", *app("EntrySerializer.entry_json", "app/serializers/entry_serializer.rb"))
        ]),
        endpoint("SpaController#show", "/*path", share: 0.08, median: 3, db: 0.0, db_n: 0, view: 0.6, error_rate: 0.0, stack: [
          branch(1.0, "running", [ "ActionView::Template#render", "actionview/lib/action_view/template.rb", "gem" ])
        ])
      ],
      jobs: [
        job("FetchFeedJob", queue: "fetch", per_hour: 90, median: 480, db: 0.2, error_rate: 0.06, stack: [
          branch(0.75, "idle", *app("Feeds::Fetcher#fetch", "app/services/feeds/fetcher.rb"), *NET_HTTP),
          branch(0.25, "running", [ "Nokogiri::XML::Document.parse", "<cfunc>", "native" ])
        ])
      ]
    )

    ALL = [ HOOK, HUB, MANOR, STREAM, FEED ].freeze

    # What fog runs from someone else's image: no gem, so everything Glass
    # knows about it is what fog says (Fog::Sync).
    Image = Struct.new(:slug, :name, keyword_init: true)
    IMAGES = [ Image.new(slug: "minio", name: "MinIO") ].freeze

    # The function the bad deploy made hot, under hook's search merge.
    REGRESSION = [ "Text::Similarity.levenshtein", "app/services/text/similarity.rb", "app" ].freeze

    # Frames above every controller action and every job.
    REQUEST_PREFIX = [
      [ "Puma::ThreadPool#spawn_thread", "puma/lib/puma/thread_pool.rb", "gem" ],
      [ "Puma::Server#process_client", "puma/lib/puma/server.rb", "gem" ],
      [ "Rack::Runtime#call", "rack/lib/rack/runtime.rb", "gem" ],
      [ "ActionDispatch::Executor#call", "actionpack/lib/action_dispatch/middleware/executor.rb", "gem" ],
      [ "ActionDispatch::Routing::RouteSet#call", "actionpack/lib/action_dispatch/routing/route_set.rb", "gem" ],
      [ "ActionController::Metal#dispatch", "actionpack/lib/action_controller/metal.rb", "gem" ],
      [ "AbstractController::Callbacks#process_action", "actionpack/lib/abstract_controller/callbacks.rb", "gem" ]
    ].freeze
    JOB_PREFIX = [
      [ "SolidQueue::Pool#post", "solid_queue/lib/solid_queue/pool.rb", "gem" ],
      [ "SolidQueue::ClaimedExecution#perform", "solid_queue/app/models/solid_queue/claimed_execution.rb", "gem" ],
      [ "ActiveJob::Execution#perform_now", "activejob/lib/active_job/execution.rb", "gem" ],
      [ "ActiveSupport::Callbacks#run_callbacks", "activesupport/lib/active_support/callbacks.rb", "gem" ]
    ].freeze
  end
end
