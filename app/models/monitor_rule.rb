# typed: strict
# frozen_string_literal: true

# A saved query with a condition, evaluated every minute by
# EvaluateMonitorsJob. Its state changes open and close Incidents.
# Named MonitorRule because `Monitor` is Ruby's own (the stdlib mutex);
# the table, the API and the console all say "monitor".
class MonitorRule < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  self.table_name = "monitors"

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      # The query's value against the threshold.
      Threshold = new("threshold")
      # The query's count is zero: nothing arrived (a heartbeat that stopped).
      Absence = new("absence")
    end
  end

  class Comparison < T::Enum
    include ApplicationEnum
    enums do
      Gt = new("gt")
      Lt = new("lt")
    end
  end

  class State < T::Enum
    include ApplicationEnum
    enums do
      Ok = new("ok")
      Alert = new("alert")
      NoData = new("no_data")
    end
  end

  WINDOW_RANGE = T.let((60..86_400), T::Range[Integer])

  has_many :incidents, foreign_key: :monitor_id, inverse_of: :monitor, dependent: :destroy
  # The one a list of monitors shows, preloadable without a monitor's whole
  # history: a monitor has at most one open at a time, newest first in case.
  # (T.unsafe: the scope runs on Incident's relation, which Sorbet sees as
  # this class body.)
  has_many :open_incidents, -> { T.unsafe(self).open.order(opened_at: :desc) }, class_name: "Incident",
    foreign_key: :monitor_id, inverse_of: :monitor

  attribute :kind, Kind
  attribute :comparison, Comparison
  attribute :state, State

  validates :name, presence: true, length: { maximum: 80 }
  validates :window_seconds, inclusion: { in: WINDOW_RANGE }
  validates :for_seconds, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 86_400 }
  validates :deploy_grace_seconds, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 86_400 }
  validate :query_has_a_source

  scope :enabled, -> { where(enabled: true) }

  sig { returns(T.nilable(Incident)) }
  def open_incident = incidents.open.order(opened_at: :desc).first

  # The app the monitor's filter names, if it names exactly one — what an
  # incident is filed under and what deploy grace looks at.
  sig { returns(T.nilable(String)) }
  def app_slug
    # ::Query — Active Record has its own AttributeMethods::Query.
    terms = ::Query::Filter.parse(query["filter"].to_s).select { |term| term.key == "app" && !term.negated && term.op == "eq" }
    terms.size == 1 && T.must(terms.first).values.size == 1 ? T.must(terms.first).values.first : nil
  rescue ::Query::Invalid
    nil
  end

  sig { returns(String) }
  def condition_text
    compute = query["compute"].presence || "count"
    case kind_enum
    when Kind::Absence then "no #{query['source'] || 'rows'} for #{window_seconds / 60} min"
    else "#{compute} #{comparison_enum == Comparison::Lt ? '<' : '>'} #{threshold} over #{window_seconds / 60} min"
    end
  end

  private

  sig { void }
  def query_has_a_source
    errors.add(:query, "needs a source") unless query.is_a?(Hash) && query["source"].present?
  end
end
