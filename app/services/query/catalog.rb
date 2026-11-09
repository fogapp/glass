# typed: strict
# frozen_string_literal: true

module Query
  # What there is to ask about: the sources and their fields, the functions,
  # the asker's apps, and every metric that has been reported with the tags
  # it carries. The query bar completes from this; the Explorer's pickers
  # are this.
  module Catalog
    extend T::Sig

    MAX_METRICS = 2_000
    MAX_VALUES = 50

    # `metrics: false` leaves the metric list out, for a caller that does
    # not show it: it is the one part read from the database.
    sig { params(context: Context, metrics: T::Boolean).returns(T::Hash[Symbol, T.untyped]) }
    def self.describe(context, metrics: true)
      {
        sources: Sources::ALL.map { |source| source_json(source) },
        # The kinds of unit of work and the facets each carries
        # (Telemetry::Work): a field of `transactions` names its facet, so a
        # picker can offer the fields that mean something for what is in
        # scope.
        kinds: Telemetry::Work::KINDS.map { |kind|
          { name: kind.name, label: kind.label, noun: kind.noun, facets: kind.facets, phases: kind.phases }
        },
        functions: { events: Compute::EVENT_FUNCTIONS, metrics: Metrics::FUNCTIONS },
        apps: context.slugs,
        metrics: metrics ? metric_list(context) : nil
      }.compact
    end

    sig { params(source: Sources::Source).returns(T::Hash[Symbol, T.untyped]) }
    def self.source_json(source)
      { name: source.name, label: source.label,
        fields: source.fields.map { |field|
          { name: field.name, label: field.label, type: field.type.serialize, measure: field.measure, unit: field.unit,
            facet: field.facet }
        } }
    end
    private_class_method :source_json

    sig { params(context: Context).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.metric_list(context)
      apps = context.app_ids
      return [] if apps.empty?

      statement = Statement.new
      sql = <<~SQL.squish
        SELECT s.name, min(s.kind) AS kind, min(s.unit) AS unit, count(*) AS series,
               array_agg(DISTINCT s.app_id) AS apps,
               array_agg(DISTINCT tag.key) FILTER (WHERE tag.key IS NOT NULL) AS tags
        FROM metric_series s LEFT JOIN LATERAL jsonb_object_keys(s.tags) AS tag(key) ON TRUE
        WHERE s.app_id IN (#{statement.bind(apps)})
        GROUP BY s.name ORDER BY s.name LIMIT #{MAX_METRICS}
      SQL
      Runner.select(statement.to_sql(sql)).map do |row|
        { name: row["name"], kind: row["kind"], unit: row["unit"], series: row["series"].to_i,
          apps: pg_array(row["apps"]).filter_map { |id| context.slug(id.to_i) }.sort,
          tags: pg_array(row["tags"]).map(&:to_s).sort }
      end
    end
    private_class_method :metric_list

    # The most common values of a field within a range — what the query bar
    # offers after `name:` and what a facet lists. The range is bounded like
    # any query's (Request::MAX_RANGE).
    sig do
      params(context: Context, source: String, key: String, from: Time, to: Time, filter: String,
        prefix: T.nilable(String), metric: T.nilable(String)).returns(T::Array[T::Hash[Symbol, T.untyped]])
    end
    def self.values(context:, source:, key:, from:, to:, filter: "", prefix: nil, metric: nil)
      Bounds.check!(from, to, max: Request::MAX_RANGE)
      return metric_values(context, metric: metric, key: key, prefix: prefix) if source == "metrics"

      definition = Sources.fetch(source)
      field = key.start_with?("@") ? nil : definition.field(key)
      return context.slugs.map { |slug| { value: slug, count: nil } } if field&.type == Sources::Type::App

      statement = Statement.new
      where = Where.new(source: definition, context: context, statement: statement)
      expression = where.expression(key)
      conditions = [ where.sql(from: from, to: to, filter: filter), "#{expression} IS NOT NULL" ]
      conditions << "#{expression}::text ILIKE #{statement.prefix(prefix)}" if prefix.present?
      sql = "SELECT #{expression} AS value, #{definition.count_sql}::float8 AS n FROM #{definition.table} " \
            "WHERE #{conditions.join(' AND ')} GROUP BY 1 ORDER BY 2 DESC LIMIT #{MAX_VALUES}"
      Runner.select(statement.to_sql(sql)).map { |row| { value: row["value"], count: row["n"] } }
    end

    sig do
      params(context: Context, metric: T.nilable(String), key: String, prefix: T.nilable(String))
        .returns(T::Array[T::Hash[Symbol, T.untyped]])
    end
    def self.metric_values(context, metric:, key:, prefix:)
      return context.slugs.map { |slug| { value: slug, count: nil } } if key == "app"

      return [] if metric.blank?

      statement = Statement.new
      where = MetricWhere.new(context: context, statement: statement)
      # The request's filter is not applied here (yet): the values a tag
      # has across the metric's series in the asker's apps.
      series = where.sql(metric: metric)
      return [] if series.nil?

      tag = where.tag(key)
      conditions = [ series, "#{tag} IS NOT NULL" ]
      conditions << "#{tag} ILIKE #{statement.prefix(prefix)}" if prefix.present?
      sql = "SELECT #{tag} AS value, count(*) AS n FROM metric_series WHERE #{conditions.join(' AND ')} " \
            "GROUP BY 1 ORDER BY 2 DESC LIMIT #{MAX_VALUES}"
      Runner.select(statement.to_sql(sql)).map { |row| { value: row["value"], count: row["n"].to_f } }
    end
    private_class_method :metric_values

    # select_all hands back a Postgres array as text ("{1,2}") for a
    # computed column it has no type for.
    sig { params(value: T.untyped).returns(T::Array[T.untyped]) }
    def self.pg_array(value)
      case value
      when Array then value
      when String then value.delete_prefix("{").delete_suffix("}").split(",").map { |item| item.delete('"') }
      else []
      end
    end
    private_class_method :pg_array
  end
end
