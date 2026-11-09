# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintainPartitionsJob do
  it "prunes the dictionaries in only the first of a day's hourly runs" do
    allow(Telemetry::Dictionaries).to receive(:prune!).and_call_original

    described_class.perform_now
    described_class.perform_now

    expect(Telemetry::Dictionaries).to have_received(:prune!).once
  end
end
