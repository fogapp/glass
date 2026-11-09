# typed: strict
# frozen_string_literal: true

module Telemetry
  # What a unit of work is. A row of
  # `transactions` is a spine every kind shares — when, which app, what it
  # was called, how long, how it ended — and a set of facets: groups of
  # fields that some kinds carry and others do not. A request has an HTTP
  # facet, a job a queue, an agent's run its tokens and its experience.
  # Facets compose, which is why they are column groups in one table rather
  # than a table per kind: a run waits in a queue like a job and makes
  # outbound calls like a request.
  #
  # A kind is a declaration, and adding one is three things: an entry here,
  # a facet builder under Ingest::Records::Txn for any facet that is new,
  # and its fields in Query::Sources. A kind nobody declared is still kept
  # (GENERIC): its spine is enough for every view that ranks, charts or
  # alerts on work.
  module Work
    extend T::Sig

    FACETS = T.let(%w[http queue rails outbound ai experience].freeze, T::Array[String])
    NAME = /\A[a-z][a-z0-9_.-]{0,39}\z/

    class Kind < T::Struct
      extend T::Sig

      const :name, String
      # What the console calls a list of them.
      const :label, String
      # What `name` holds for this kind.
      const :noun, String
      const :facets, T::Array[String]
      # The measures that add up to the duration, in the order a breakdown
      # draws them; what is left over is the kind's unattributed time.
      const :phases, T::Array[String]
      # What a sentence counts them in: "1 job run", "40 job runs".
      const :one, String
      const :many, String
      # A name's rows, as a sentence about it says them: "runs of this job".
      const :members, String
      # Whether its latency is the app's own: a run's duration includes a
      # person thinking, which no fix will shorten.
      const :timed, T::Boolean, default: false

      sig { params(count: T.untyped).returns(String) }
      def counted(count) = count.to_f.round == 1 ? one : many
    end

    REQUEST = Kind.new(name: "request", label: "Requests", noun: "Endpoint",
      facets: %w[http rails outbound], phases: %w[db view ext],
      one: "request", many: "requests", members: "requests to this endpoint", timed: true)
    JOB = Kind.new(name: "job", label: "Jobs", noun: "Job",
      facets: %w[queue rails outbound], phases: %w[db view ext],
      one: "job run", many: "job runs", members: "runs of this job", timed: true)
    RUN = Kind.new(name: "run", label: "Agent runs", noun: "Agent",
      facets: %w[queue outbound ai experience], phases: %w[queue_ms prep model_ms tool_ms wait deliver],
      one: "agent run", many: "agent runs", members: "this agent's runs")

    KINDS = T.let([ REQUEST, JOB, RUN ].freeze, T::Array[Kind])

    # The kinds whose latency is the app's own (Kind#timed).
    TIMED = T.let(KINDS.select(&:timed).map(&:name).freeze, T::Array[String])

    # A kind Glass has no declaration for. It is read generously — any
    # field of any facet it sends is kept — because the agent that sent it
    # knows something the server does not yet.
    GENERIC = Kind.new(name: "*", label: "Other work", noun: "Name", facets: FACETS, phases: %w[db view ext],
      one: "unit of work", many: "units of work", members: "these units of work")

    # One part of where a timed kind's time goes, as a breakdown labels it
    # and as a sentence says it.
    class Part < T::Struct
      const :name, String
      const :label, String
      const :phrase, String
      # Time already inside the other parts (the collector pauses whatever
      # is running), so never the part that "grew most".
      const :overlaps, T::Boolean, default: false
    end

    # How a request's or a job's time divides: its phases, the collector's
    # pauses within them, and what is left to the app's own code.
    PARTS = T.let([
      Part.new(name: "db", label: "Database", phrase: "the database"),
      Part.new(name: "view", label: "Views", phrase: "views"),
      Part.new(name: "ext", label: "Outbound calls", phrase: "outbound calls"),
      Part.new(name: "gc", label: "Garbage collection", phrase: "garbage collection", overlaps: true),
      Part.new(name: "app_time", label: "The app's own code", phrase: "the app's own code")
    ].freeze, T::Array[Part])

    sig { params(name: String).returns(Kind) }
    def self.kind(name) = KINDS.find { |kind| kind.name == name } || GENERIC

    sig { params(value: T.untyped).returns(T::Boolean) }
    def self.valid_name?(value)
      return false unless value.is_a?(String)

      NAME.match?(value)
    end
  end
end
