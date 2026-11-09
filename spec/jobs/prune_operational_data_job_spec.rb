# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe PruneOperationalDataJob do
  let(:household) { create_household }
  let(:rule) do
    MonitorRule.create!(household: household, name: "slow", kind: "threshold", comparison: "gt", threshold: 1,
      window_seconds: 300, query: { "source" => "transactions" })
  end

  def incident(opened_at:, closed_at: nil)
    Incident.create!(household: household, monitor: rule, opened_at: opened_at, closed_at: closed_at)
  end

  it "ages out incidents closed past the window, never an open one however old" do
    expired = incident(opened_at: 3.years.ago, closed_at: 2.years.ago)
    recent = incident(opened_at: 2.years.ago, closed_at: 1.month.ago)
    still_open = incident(opened_at: 3.years.ago)

    described_class.perform_now

    expect(Incident.where(id: [ expired, recent, still_open ].map(&:id)).pluck(:id)).to contain_exactly(recent.id, still_open.id)
    expect(rule.reload.open_incident).to eq(still_open)
  end
end
