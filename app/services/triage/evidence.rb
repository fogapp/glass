# typed: strict
# frozen_string_literal: true

module Triage
  # One piece of what a finding rests on, in a shape the console draws
  # without knowing which detector made it: a chart (a query the console
  # runs itself, so it is live and every point leads to its rows), a table
  # of a breakdown, the traces, log lines, functions or deploys involved.
  class Evidence < T::Struct
    extend T::Sig

    class Type < T::Enum
      include ApplicationEnum
      enums do
        Chart = new("chart")
        Table = new("table")
        Traces = new("traces")
        Logs = new("logs")
        Functions = new("functions")
        Markers = new("markers")
      end
    end

    class Column < T::Struct
      const :key, String
      const :label, String
      # How the console formats it (formatUnit): ms, ratio, usd, count…
      const :unit, T.nilable(String), default: nil
    end

    # A labelled fact about the subject: its app, route, release, queue.
    class Fact < T::Struct
      const :label, String
      const :value, String
    end

    const :type, Type
    const :title, String
    const :note, T.nilable(String), default: nil
    # A chart's question: a Query::Request's params (QuerySpec).
    const :query, T.nilable(T::Hash[String, T.untyped]), default: nil
    const :columns, T::Array[Column], default: []
    const :rows, T::Array[T::Hash[String, T.untyped]], default: []

    sig { returns(T::Boolean) }
    def empty? = type != Type::Chart && rows.empty?
  end
end
