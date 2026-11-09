# typed: strict
# frozen_string_literal: true

module Query
  # A filter, compiled: the WHERE clause every shape of a query shares —
  # the time range, the asker's apps, and each term of what they typed.
  class Where
    extend T::Sig

    NUMBER = /\A-?\d+(?:\.\d+)?\z/
    # A value read out of attrs as a number, or NULL when it is not one —
    # a cast that cannot raise on the one row that holds "n/a".
    NUMERIC_TEXT = "'^-?[0-9]+(\\.[0-9]+)?$'"
    DURATION_UNITS = T.let({ "ms" => 1.0, "s" => 1_000.0, "m" => 60_000.0, "h" => 3_600_000.0 }.freeze,
      T::Hash[String, Float])
    HEX32 = /\A[0-9a-f]{32}\z/

    sig { params(source: Sources::Source, context: Context, statement: Statement).void }
    def initialize(source:, context:, statement:)
      @source = source
      @context = context
      @statement = statement
    end

    sig { params(from: Time, to: Time, filter: String).returns(String) }
    def sql(from:, to:, filter:)
      clauses = [ "ts >= #{@statement.bind(from)}", "ts < #{@statement.bind(to)}" ]
      apps = @context.app_ids
      clauses << (apps.empty? ? "FALSE" : "app_id IN (#{@statement.bind(apps)})")
      Filter.parse(filter).each { |term| clauses << term_sql(term) }
      clauses.join(" AND ")
    end

    # The SQL a field is grouped and selected by.
    sig { params(name: String).returns(String) }
    def expression(name)
      return "#{attrs!(name)}->>#{@statement.bind(name.delete_prefix('@'))}" if name.start_with?("@")

      field = field!(name)
      field.type == Sources::Type::Trace ? "replace(#{field.sql}::text, '-', '')" : field.sql
    end

    sig { params(name: String).returns(Sources::Field) }
    def field!(name) = @source.field!(name)

    # A term's condition, negated when the term is. IS NOT TRUE rather than
    # NOT: a row where the column is NULL does not have that value either,
    # and should survive `-status:error`. Shared with MetricWhere.
    sig { params(term: Filter::Term, condition: String).returns(String) }
    def self.negatable(term, condition) = term.negated ? "(#{condition}) IS NOT TRUE" : "(#{condition})"

    # `app:` names as a condition on `column`. No such app matches nothing
    # rather than fail (see Context#app_id). Shared with MetricWhere.
    sig { params(column: String, slugs: T::Array[String], context: Context, statement: Statement).returns(String) }
    def self.apps_sql(column, slugs, context:, statement:)
      ids = slugs.filter_map { |slug| context.app_id(slug) }
      ids.empty? ? "FALSE" : "#{column} IN (#{statement.bind(ids)})"
    end

    private

    sig { params(term: Filter::Term).returns(String) }
    def term_sql(term)
      key = term.key
      condition =
        if key.nil? then text_sql(T.must(term.values.first))
        elsif key.start_with?("@") then attr_sql(key.delete_prefix("@"), term)
        else field_sql(field!(key), term)
        end
      Where.negatable(term, condition)
    end

    sig { params(text: String).returns(String) }
    def text_sql(text)
      raise Invalid, "Free text needs a source with text to search" if @source.text_fields.empty?

      pattern = @statement.bind("%#{Statement.escape_like(text)}%")
      @source.text_fields.map { |name| "#{field!(name).sql} ILIKE #{pattern}" }.join(" OR ")
    end

    sig { params(field: Sources::Field, term: Filter::Term).returns(String) }
    def field_sql(field, term)
      return "#{field.sql} IS NOT NULL" if term.op == "present"

      case field.type
      when Sources::Type::App then app_sql(field, term)
      when Sources::Type::Bool then bool_sql(field, term)
      when Sources::Type::Trace then trace_sql(field, term)
      when Sources::Type::Int, Sources::Type::Number then number_sql(field.sql, term, unit: field.unit, name: field.name)
      else text_field_sql(field.sql, term, name: field.name)
      end
    end

    sig { params(sql: String, term: Filter::Term, name: String).returns(String) }
    def text_field_sql(sql, term, name:)
      raise Invalid, "“#{name}” is text — it cannot be compared with > or <" unless term.op == "eq"

      @statement.matches(sql, term.values)
    end

    sig { params(sql: String, term: Filter::Term, unit: T.nilable(String), name: String).returns(String) }
    def number_sql(sql, term, unit:, name:)
      values = term.values
      case term.op
      when "eq"
        values.map { |value| status_class(sql, value) || "#{sql} = #{number(value, unit, name)}" }.join(" OR ")
      when "range"
        "#{sql} >= #{number(T.must(values[0]), unit, name)} AND #{sql} <= #{number(T.must(values[1]), unit, name)}"
      else
        operator = { "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=" }.fetch(term.op)
        "#{sql} #{operator} #{number(T.must(values.first), unit, name)}"
      end
    end

    # `http_status:5xx` — a class of statuses, the way people say it.
    sig { params(sql: String, value: String).returns(T.nilable(String)) }
    def status_class(sql, value)
      match = value.match(/\A([1-5])xx\z/i)
      match && "#{sql} >= #{match[1].to_i * 100} AND #{sql} < #{(match[1].to_i + 1) * 100}"
    end

    # A number a person typed, as a bound value; with a duration unit when
    # the field is one (`250ms`, `1.5s`).
    sig { params(value: String, unit: T.nilable(String), name: String).returns(String) }
    def number(value, unit, name)
      if unit == "ms" && (match = value.match(/\A(-?\d+(?:\.\d+)?)(ms|s|m|h)\z/))
        return @statement.bind(match[1].to_f * DURATION_UNITS.fetch(T.must(match[2])))
      end
      raise Invalid, "“#{name}” is a number — “#{value}” is not" unless NUMBER.match?(value)

      @statement.bind(value.to_f)
    end

    sig { params(field: Sources::Field, term: Filter::Term).returns(String) }
    def app_sql(field, term)
      raise Invalid, "“app” takes app names, like app:hook" unless term.op == "eq"

      Where.apps_sql(field.sql, term.values, context: @context, statement: @statement)
    end

    sig { params(field: Sources::Field, term: Filter::Term).returns(String) }
    def bool_sql(field, term)
      value = term.values.first.to_s.downcase
      raise Invalid, "“#{field.name}” is true or false" unless term.op == "eq" && %w[true false].include?(value)

      "#{field.sql} = #{value.upcase}"
    end

    sig { params(field: Sources::Field, term: Filter::Term).returns(String) }
    def trace_sql(field, term)
      ids = term.values.map { |value| value.downcase.delete("-") }
      raise Invalid, "A trace id is 32 hex characters" unless term.op == "eq" && ids.all? { |id| HEX32.match?(id) }

      "#{field.sql} IN (#{@statement.bind(ids)})"
    end

    # A free-form attribute: text by default, a number when it is compared
    # like one.
    sig { params(key: String, term: Filter::Term).returns(String) }
    def attr_sql(key, term)
      text = "#{attrs!("@#{key}")}->>#{@statement.bind(key)}"
      return "#{text} IS NOT NULL" if term.op == "present"
      return text_field_sql(text, term, name: "@#{key}") if term.op == "eq"

      numeric = "(CASE WHEN #{text} ~ #{NUMERIC_TEXT} THEN (#{text})::float8 END)"
      number_sql(numeric, term, unit: nil, name: "@#{key}")
    end

    # The attributes column, for a source that has one.
    sig { params(name: String).returns(String) }
    def attrs!(name)
      attrs = @source.attrs
      return attrs if attrs

      raise Invalid, "#{@source.name} rows carry no attributes — “#{name}” has nothing to read"
    end
  end
end
