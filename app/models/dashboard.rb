# typed: strict
# frozen_string_literal: true

# A grid of saved queries. Widgets are documents, not rows:
# a dashboard is edited and rendered whole, and each widget is the Explorer
# state that made it, with its place on a twelve-column grid (x and w in
# columns, y and h in rows). The console keeps the grid settled — no
# overlaps, no holes (frontend/src/lib/dashboardLayout.ts); a widget that
# arrives without a place (a pin from Explore) takes the first that fits.
# A widget is a query or a header: a line of text (and a quieter one under
# it) that names the stretch of dashboard below it.
class Dashboard < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Query = new("query")
      Header = new("header")
    end
  end

  class HeaderSize < T::Enum
    include ApplicationEnum
    enums do
      Small = new("sm")
      Medium = new("md")
      Large = new("lg")
      Huge = new("xl")
    end
  end

  # What a chart's header and subheader can be made of, read from its query
  # as it is now; in this order, whatever order they were picked in. A
  # label with text of its own shows that instead.
  class LabelPart < T::Enum
    include ApplicationEnum
    enums do
      Source = new("source")
      Metric = new("metric")
      Compute = new("compute")
      GroupBy = new("group_by")
      Apps = new("apps")
      Filter = new("filter")
    end
  end
  TITLE_PARTS = T.let(%w[metric compute group_by].freeze, T::Array[String])
  SUBTITLE_PARTS = T.let(%w[filter].freeze, T::Array[String])

  # The icons a header may wear, by their lucide names; the console draws
  # each (frontend/src/lib/headerIcons.ts), and one it can't draw fails its
  # build.
  HEADER_ICONS = T.let(%w[
    activity bot bug chart-line clock coins cpu database flame gauge globe hard-drive heart info layers mail
    message-square network rocket server shield shopping-cart sparkles star timer trending-up triangle-alert
    users workflow zap
  ].freeze, T::Array[String])
  # A new header's height in rows, by its size: room for both lines.
  HEADER_ROWS = T.let({ "sm" => 2, "md" => 2, "lg" => 3, "xl" => 3 }.freeze, T::Hash[String, Integer])
  HEADER_MIN_H = 1

  MAX_WIDGETS = 40
  COLUMNS = 12
  MIN_W = 2
  MIN_H = 4
  MAX_H = 20
  MAX_Y = 1000
  # What a widget was before it had a place: a third, two thirds or the
  # width of a three-column grid, and its chart's height in pixels.
  LEGACY_SPANS = T.let([ 1, 2, 3 ].freeze, T::Array[Integer])
  LEGACY_ROWS = T.let({ 120 => 5, 180 => 6, 260 => 8, 360 => 10 }.freeze, T::Hash[Integer, Integer])

  before_validation :arrange_widgets

  validates :name, presence: true, length: { maximum: 80 }
  validate :widgets_are_well_formed

  # A widget as stored, from whatever a client sent: only the keys its kind
  # has — a query's spec narrowed to the query fields, a header's size and
  # icon to the ones there are.
  sig { params(raw: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
  def self.widget_from(raw)
    hash = plain(raw)
    return nil if hash.nil?

    kind = Kind.try_deserialize(hash["kind"].to_s) || Kind::Query
    own = kind == Kind::Header ? header_from(hash) : query_from(hash)
    size = own.extract!("w", "h")
    w = (whole(hash["w"]) || size["w"]).clamp(MIN_W, COLUMNS)
    h = (whole(hash["h"]) || size["h"]).clamp(kind == Kind::Header ? HEADER_MIN_H : MIN_H, MAX_H)
    { "id" => hash["id"].to_s.presence || SecureRandom.hex(6), "kind" => kind.serialize, "title" => hash["title"].to_s.first(120) }
      .merge(own)
      .merge("x" => whole(hash["x"])&.clamp(0, COLUMNS - w), "y" => whole(hash["y"])&.clamp(0, MAX_Y), "w" => w, "h" => h)
  end

  # A query's own keys, and the size it takes when it names none. Its
  # title and subtitle are text of its own; when blank, the parts named.
  sig { params(hash: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def self.query_from(hash)
    spec = plain(hash["spec"]) || {}
    span = hash["span"].to_i
    {
      "subtitle" => hash["subtitle"].to_s.first(200),
      "title_parts" => label_parts(hash["title_parts"], TITLE_PARTS),
      "subtitle_parts" => label_parts(hash["subtitle_parts"], SUBTITLE_PARTS),
      "spec" => spec.slice("source", "shape", "filter", "compute", "group_by", "metric", "field", "limit"),
      "w" => LEGACY_SPANS.include?(span) ? span * 4 : 4,
      "h" => LEGACY_ROWS[hash["height"].to_i] || 6
    }
  end
  private_class_method :query_from

  # The parts there are, in their order; `fallback` when none were sent.
  sig { params(raw: T.untyped, fallback: T::Array[String]).returns(T::Array[String]) }
  def self.label_parts(raw, fallback)
    return fallback unless raw.is_a?(Array)

    picked = raw.map(&:to_s)
    LabelPart.values.map(&:serialize).select { |part| picked.include?(part) }
  end
  private_class_method :label_parts

  # A header's own keys, and the size it takes when it names none: the
  # width of the dashboard, tall enough for its text.
  sig { params(hash: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def self.header_from(hash)
    size = HeaderSize.try_deserialize(hash["size"].to_s) || HeaderSize::Medium
    icon = hash["icon"].to_s
    {
      "subtitle" => hash["subtitle"].to_s.first(200),
      "size" => size.serialize,
      "icon" => HEADER_ICONS.include?(icon) ? icon : nil,
      "w" => COLUMNS,
      "h" => HEADER_ROWS.fetch(size.serialize)
    }
  end
  private_class_method :header_from

  # Widgets as stored, each with a place: those without one take the first
  # spot that fits, top to bottom and left to right, in the order given.
  sig { params(raw: T::Array[T.untyped]).returns(T::Array[T::Hash[String, T.untyped]]) }
  def self.arrange(raw)
    widgets = raw.filter_map { |widget| widget_from(widget) }
    placed = widgets.select { |widget| widget["x"] && widget["y"] }
    widgets.map do |widget|
      next widget if widget["x"] && widget["y"]

      widget.merge(first_fit(placed, widget["w"], widget["h"])).tap { |done| placed << done }
    end
  end

  sig { params(placed: T::Array[T::Hash[String, T.untyped]], w: Integer, h: Integer).returns(T::Hash[String, Integer]) }
  def self.first_fit(placed, w, h)
    bottom = placed.map { |other| other["y"] + other["h"] }.max || 0
    (0..bottom).each do |y|
      (0..(COLUMNS - w)).each do |x|
        clear = placed.none? { |o| x < o["x"] + o["w"] && o["x"] < x + w && y < o["y"] + o["h"] && o["y"] < y + h }
        return { "x" => x, "y" => y } if clear
      end
    end
    { "x" => 0, "y" => bottom }
  end
  private_class_method :first_fit

  sig { params(value: T.untyped).returns(T.nilable(Integer)) }
  def self.whole(value)
    return value if value.is_a?(Integer)
    return value.round if value.is_a?(Float) && value.finite?
    return value.to_i if value.is_a?(String) && value.match?(/\A-?\d+\z/)

    nil
  end
  private_class_method :whole

  # Request parameters or a stored hash, as a plain string-keyed hash.
  sig { params(raw: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
  def self.plain(raw)
    return raw.to_unsafe_h.transform_keys(&:to_s) if raw.respond_to?(:to_unsafe_h)
    return raw.transform_keys(&:to_s) if raw.is_a?(Hash)

    nil
  end
  private_class_method :plain

  private

  # Only when the widgets changed (a rename leaves them be), and never more
  # than one past the limit: arranging is quadratic, and the validation
  # refuses the list anyway.
  sig { void }
  def arrange_widgets
    return unless widgets_changed? && widgets.is_a?(Array) && widgets.all?(Hash)

    self.widgets = Dashboard.arrange(widgets.first(MAX_WIDGETS + 1))
  end

  sig { void }
  def widgets_are_well_formed
    return errors.add(:widgets, "must be a list") unless widgets.is_a?(Array)
    return errors.add(:widgets, "at most #{MAX_WIDGETS}") if widgets.size > MAX_WIDGETS

    widgets.each do |widget|
      next errors.add(:widgets, "each must be an object") unless widget.is_a?(Hash)

      if widget["kind"] == Kind::Header.serialize
        errors.add(:widgets, "a header needs some text") if widget["title"].blank?
      elsif !(widget["spec"].is_a?(Hash) && widget["spec"]["source"].present?)
        errors.add(:widgets, "each needs a spec with a source")
      end
    end
  end
end
