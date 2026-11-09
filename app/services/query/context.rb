# typed: strict
# frozen_string_literal: true

module Query
  # Who is asking. Telemetry rows name their app by number and live in a
  # database that cannot join to the one the apps are in, so the mapping
  # between slug and number is resolved here, once per request — and it is
  # also the access boundary: a query can only ever see the asker's apps.
  class Context
    extend T::Sig

    sig { params(household: Household).void }
    def initialize(household)
      apps = App.where(household_id: household.id).pluck(:telemetry_id, :slug)
      @slug_by_id = T.let(apps.to_h, T::Hash[Integer, String])
      @id_by_slug = T.let(@slug_by_id.invert, T::Hash[String, Integer])
    end

    sig { returns(T::Array[Integer]) }
    def app_ids = @slug_by_id.keys

    sig { params(id: T.untyped).returns(T.nilable(String)) }
    def slug(id) = id.is_a?(Integer) ? @slug_by_id[id] : nil

    # nil when no such app: the caller turns that into "matches nothing",
    # not into an error — a saved view naming a deleted app should draw an
    # empty chart, not fail.
    sig { params(slug: String).returns(T.nilable(Integer)) }
    def app_id(slug) = @id_by_slug[slug.downcase]

    sig { returns(T::Array[String]) }
    def slugs = @id_by_slug.keys.sort

    # The apps a filter's `app:` terms leave a query, by slug — nil when it
    # has none, and the query reads every app. An answer says them, so a
    # chart of one app draws that app's markers and no other's.
    sig { params(filter: T.nilable(String)).returns(T.nilable(T::Array[String])) }
    def apps_in(filter)
      terms = Filter.parse(filter).select { |term| term.key == "app" && term.op == "eq" }
      return nil if terms.empty?

      kept = terms.reduce(app_ids) do |ids, term|
        named = term.values.filter_map { |name| app_id(name) }
        term.negated ? ids - named : ids & named
      end
      kept.filter_map { |id| slug(id) }.sort
    end
  end
end
