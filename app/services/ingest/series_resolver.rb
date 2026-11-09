# typed: strict
# frozen_string_literal: true

module Ingest
  # (app, metric name, tags) → series id, creating the series on first
  # sight. Every batch asks for the same few hundred series, so answers are
  # remembered per process; only a genuinely new series costs a query.
  #
  # Also where runaway cardinality stops: past
  # MAX_SERIES_PER_METRIC tag sets for one name in one app, a new tag set is
  # folded into a single overflow series instead of becoming a row per
  # request id someone put in a tag. A tag set sent there is remembered
  # there, so the limit is checked once per tag set, not once per batch.
  #
  # What is remembered is forgotten after Telemetry::Dictionaries::CACHE_TTL:
  # series nobody has sent for longer than any point is kept are pruned,
  # and a process must not go on naming one it looked up long ago
  # (Telemetry::Dictionaries says why an hour is enough).
  class SeriesResolver
    extend T::Sig

    MAX_SERIES_PER_METRIC = 2_000
    OVERFLOW_TAGS = T.let({ "glass_overflow" => "true" }.freeze, T::Hash[String, String])
    CACHE_LIMIT = 100_000

    Key = T.type_alias { [ Integer, String, Integer ] }

    @cache = T.let(DictionaryCache[Key].new(limit: CACHE_LIMIT), DictionaryCache[Key])

    class << self
      extend T::Sig

      sig { void }
      def reset!
        @cache.reset!
      end

      # Series ids for the points, in the same order.
      sig { params(app: App, points: T::Array[Records::Metric::Point]).returns(T::Array[Integer]) }
      def resolve(app, points)
        app_id = app.telemetry_id
        keys = points.map { |point| [ app_id, point.name, Telemetry::MetricSeries.tags_hash(point.tags) ] }
        known = @cache.fetch_many(keys)
        missing = keys.zip(points).reject { |key, _| known.key?(key) }.uniq(&:first)

        unless missing.empty?
          found = lookup(app_id, missing.map(&:first))
          created = create(app_id, missing.reject { |key, _| found.key?(key) })
          known = known.merge(found, created)
          @cache.remember(found.merge(created))
        end

        # A tag set past the limit is remembered as its overflow series, so
        # a runaway metric costs a query once per tag set, not per batch —
        # until the cache's TTL, like every other answer here.
        overflowed = T.let({}, T::Hash[Key, Integer])
        ids = keys.zip(points).map do |key, point|
          known[key] || (overflowed[key] ||= overflow_id(app_id, T.must(point)))
        end
        @cache.remember(overflowed)
        ids
      end

      private

      sig { params(app_id: Integer, keys: T::Array[Key]).returns(T::Hash[Key, Integer]) }
      def lookup(app_id, keys)
        return {} if keys.empty?

        rows = Telemetry::MetricSeries.where(app_id: app_id, name: keys.map { |key| key[1] }.uniq,
          tags_hash: keys.map { |key| key[2] }.uniq).pluck(:name, :tags_hash, :id)
        wanted = keys.to_set
        rows.each_with_object({}) do |(name, hash, id), out|
          key = [ app_id, name, hash ]
          out[key] = id if wanted.include?(key)
        end
      end

      # Create what is missing, up to each metric's limit. Anything past the
      # limit is left out of the answer, which sends it to the overflow
      # series. ON CONFLICT covers a concurrent batch creating the same one.
      sig do
        params(app_id: Integer, missing: T::Array[[ Key, T.nilable(Records::Metric::Point) ]])
          .returns(T::Hash[Key, Integer])
      end
      def create(app_id, missing)
        return {} if missing.empty?

        names = missing.map { |key, _| key[1] }.uniq
        counts = Telemetry::MetricSeries.where(app_id: app_id, name: names).group(:name).count
        rows = missing.filter_map do |key, point|
          point = T.must(point)
          next if counts.fetch(point.name, 0) >= MAX_SERIES_PER_METRIC

          counts[point.name] = counts.fetch(point.name, 0) + 1
          { app_id: app_id, name: point.name, kind: point.kind.serialize, unit: point.unit, tags: point.tags, tags_hash: key[2] }
        end
        return {} if rows.empty?

        Telemetry::MetricSeries.insert_all(rows, unique_by: %i[app_id name tags_hash]) # rubocop:disable Rails/SkipsModelValidations
        lookup(app_id, rows.map { |row| [ app_id, row[:name], row[:tags_hash] ] })
      end

      sig { params(app_id: Integer, point: Records::Metric::Point).returns(Integer) }
      def overflow_id(app_id, point)
        hash = Telemetry::MetricSeries.tags_hash(OVERFLOW_TAGS)
        key = [ app_id, point.name, hash ]
        cached = @cache.fetch_many([ key ])[key]
        return cached if cached

        Telemetry::MetricSeries.insert_all( # rubocop:disable Rails/SkipsModelValidations
          [ { app_id: app_id, name: point.name, kind: point.kind.serialize, unit: point.unit,
              tags: OVERFLOW_TAGS, tags_hash: hash } ],
          unique_by: %i[app_id name tags_hash]
        )
        id = Telemetry::MetricSeries.where(app_id: app_id, name: point.name, tags_hash: hash).pick(:id)
        @cache.remember({ key => id })
        id
      end
    end
  end
end
