# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard do
  let(:spec) { { "source" => "transactions" } }
  let(:places) { ->(widgets) { widgets.map { |widget| widget.values_at("x", "y", "w", "h") } } }

  describe ".arrange" do
    it "gives a widget without a place the first spot that fits, and keeps those that have one" do
      widgets = described_class.arrange([
        { "spec" => spec, "x" => 0, "y" => 0, "w" => 6, "h" => 6 },
        { "spec" => spec, "x" => 0, "y" => 6, "w" => 12, "h" => 4 },
        { "spec" => spec, "w" => 6, "h" => 6 },
        { "spec" => spec, "w" => 8, "h" => 4 }
      ])
      expect(places.call(widgets)).to eq([ [ 0, 0, 6, 6 ], [ 0, 6, 12, 4 ], [ 6, 0, 6, 6 ], [ 0, 10, 8, 4 ] ])
    end

    it "lays a widget from before the grid out as its flow did" do
      widgets = described_class.arrange([
        { "spec" => spec, "span" => 1, "height" => 180 },
        { "spec" => spec, "span" => 2, "height" => 360 },
        { "spec" => spec, "span" => 3, "height" => 120 }
      ])
      expect(places.call(widgets)).to eq([ [ 0, 0, 4, 6 ], [ 4, 0, 8, 10 ], [ 0, 10, 12, 5 ] ])
      expect(widgets.first.keys).to eq(%w[id kind title subtitle title_parts subtitle_parts spec x y w h])
      expect(widgets.first["kind"]).to eq("query")
    end

    it "keeps a widget inside the grid and the sizes it may take" do
      widget = described_class.arrange([ { "spec" => spec, "x" => 11, "y" => -3, "w" => 40, "h" => 1 } ]).first
      expect(widget.values_at("x", "y", "w", "h")).to eq([ 0, 0, 12, 4 ])
    end
  end

  describe "a chart's labels" do
    it "are made of the query's parts unless it has text of its own, in their order and only those there are" do
      widget = described_class.widget_from("spec" => spec, "title" => "", "title_parts" => %w[filter bogus apps source], "subtitle" => "Mine")
      expect(widget).to include("title" => "", "title_parts" => %w[source apps filter], "subtitle" => "Mine", "subtitle_parts" => %w[filter])
    end

    it "start from what the measure is and how it's grouped, and may be nothing at all" do
      expect(described_class.widget_from("spec" => spec)).to include("title_parts" => %w[metric compute group_by], "subtitle_parts" => %w[filter])
      expect(described_class.widget_from("spec" => spec, "subtitle_parts" => [])).to include("subtitle_parts" => [])
    end
  end

  describe "a header" do
    it "keeps its text, size and icon, and takes the dashboard's width and room for both lines" do
      widget = described_class.widget_from("kind" => "header", "title" => "Checkout", "subtitle" => "What buyers see", "size" => "xl", "icon" => "shopping-cart", "spec" => spec)
      expect(widget).to include("kind" => "header", "title" => "Checkout", "subtitle" => "What buyers see", "size" => "xl", "icon" => "shopping-cart", "w" => 12, "h" => 3)
      expect(widget).not_to have_key("spec")
    end

    it "drops a size or icon there isn't, and may be a single row" do
      widget = described_class.widget_from("kind" => "header", "title" => "Jobs", "size" => "huge", "icon" => "skull", "h" => 1)
      expect(widget).to include("size" => "md", "icon" => nil, "h" => 1)
    end

    it "needs some text" do
      household = create_household
      dashboard = household.dashboards.new(name: "Evening", widgets: [ { "kind" => "header", "title" => " " } ])
      expect(dashboard).not_to be_valid
      expect(dashboard.errors[:widgets]).to include("a header needs some text")
    end
  end

  it "refuses a list past the limit without arranging all of it" do
    household = create_household
    widgets = Array.new(5_000) { { "spec" => { "source" => "transactions" } } }
    expect(described_class).to receive(:arrange).with(have_attributes(size: described_class::MAX_WIDGETS + 1)).and_call_original
    dashboard = household.dashboards.new(name: "Huge", widgets: widgets)
    expect(dashboard).not_to be_valid
    expect(dashboard.errors[:widgets]).to include("at most #{described_class::MAX_WIDGETS}")
  end
end
