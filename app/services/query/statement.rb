# typed: strict
# frozen_string_literal: true

module Query
  # SQL under construction: fragments whose identifiers came from the
  # registry, and the values a person supplied, kept apart until the
  # adapter quotes them. `bind` is the only way a value gets in.
  class Statement
    extend T::Sig

    sig { void }
    def initialize
      @binds = T.let({}, T::Hash[Symbol, T.untyped])
    end

    # Registers a value and answers its placeholder.
    sig { params(value: T.untyped).returns(String) }
    def bind(value)
      name = :"b#{@binds.size}"
      @binds[name] = value
      ":#{name}"
    end

    # `text` as a LIKE pattern matching itself: its wildcards and the
    # escape character, escaped.
    sig { params(text: String).returns(String) }
    def self.escape_like(text) = text.gsub(/[\\%_]/) { |char| "\\#{char}" }

    # A LIKE pattern for what starts with `prefix`, bound.
    sig { params(prefix: String).returns(String) }
    def prefix(prefix) = bind("#{Statement.escape_like(prefix)}%")

    # `sql` matching any of `values`, where a `*` in a value is a wildcard:
    # the exact values as one IN, each pattern as a LIKE.
    sig { params(sql: String, values: T::Array[String]).returns(String) }
    def matches(sql, values)
      exact, patterns = values.partition { |value| value.exclude?("*") }
      clauses = patterns.map { |value| "#{sql} LIKE #{bind(Statement.escape_like(value).tr('*', '%'))}" }
      clauses << "#{sql} IN (#{bind(exact)})" if exact.any?
      clauses.join(" OR ")
    end

    sig { params(sql: String).returns(String) }
    def to_sql(sql) = TelemetryRecord.sanitize_sql_array([ sql, @binds ])
  end
end
