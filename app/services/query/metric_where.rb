# typed: strict
# frozen_string_literal: true

module Query
  # A filter over metric_series, compiled: one metric's series in the
  # asker's apps, narrowed by tag terms (`route:/up`, `-region:eu`, `app:hook`).
  # Where's counterpart for the one table that keeps its dimensions as a tags
  # object rather than columns; app terms and negation read exactly as
  # Where reads them. Shared by Metrics (which series to fold) and Catalog
  # (which values a tag has).
  class MetricWhere
    extend T::Sig

    sig { params(context: Context, statement: Statement).void }
    def initialize(context:, statement:)
      @context = context
      @statement = statement
    end

    # nil when the asker has no apps: there is nothing to read.
    sig { params(metric: String, filter: T.nilable(String)).returns(T.nilable(String)) }
    def sql(metric:, filter: nil)
      apps = @context.app_ids
      return nil if apps.empty?

      clauses = [ "name = #{@statement.bind(metric)}", "app_id IN (#{@statement.bind(apps)})" ]
      Filter.parse(filter).each { |term| clauses << term_sql(term) }
      clauses.join(" AND ")
    end

    # The SQL a tag is read by.
    sig { params(key: String).returns(String) }
    def tag(key) = "tags->>#{@statement.bind(key)}"

    private

    sig { params(term: Filter::Term).returns(String) }
    def term_sql(term)
      key = term.key || raise(Invalid, "A metrics filter is tag:value terms — free text has nothing to search")
      condition =
        if key == "app"
          Where.apps_sql("app_id", term.values, context: @context, statement: @statement)
        else
          case term.op
          when "present" then "#{tag(key)} IS NOT NULL"
          when "eq" then @statement.matches(tag(key), term.values)
          else raise Invalid, "Tags are text — “#{key}” cannot be compared with > or <"
          end
        end
      Where.negatable(term, condition)
    end
  end
end
