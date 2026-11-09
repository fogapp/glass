# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe EvaluateMonitorsJob do
  def monitor(household, name)
    MonitorRule.create!(household: household, name: name, kind: "threshold", comparison: "gt", threshold: 100,
      window_seconds: 300, query: { "source" => "transactions", "filter" => "app:hook", "compute" => "count" })
  end

  it "evaluates every enabled monitor, building one query context per household" do
    home = create_household
    cabin = create_household(name: "Cabin")
    create_app(household: home, slug: "hook")
    rules = [ monitor(home, "one"), monitor(home, "two"), monitor(cabin, "three") ]
    allow(Query::Context).to receive(:new).and_call_original

    described_class.perform_now

    expect(Query::Context).to have_received(:new).twice
    rules.each(&:reload)
    expect(rules.map(&:last_evaluated_at)).to all(be_present)
    expect(rules.map(&:last_error)).to all(be_nil)
  end
end
