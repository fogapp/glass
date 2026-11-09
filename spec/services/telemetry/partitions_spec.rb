# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Telemetry::Partitions do
  let(:today) { Time.now.utc.to_date }
  let(:far) { Date.new(2030, 1, 10) }

  # Dropping is real DDL on the shared test database, so whatever an example
  # dropped is put back for the examples after it.
  after do
    described_class.list.select { |p| p.day.year == 2030 }.each do |partition|
      TelemetryRecord.connection.execute("DROP TABLE IF EXISTS #{partition.name}")
    end
    described_class.ensure!
  end

  it "creates the days around today, once" do
    created = described_class.ensure!(today: far)
    expect(created).to eq(Telemetry::Tables::ALL.size * 5)
    expect(described_class.ensure!(today: far)).to eq(0)
    days = described_class.list.select { |p| p.table == "transactions" && p.day.year == 2030 }.map(&:day)
    expect(days).to eq(((far - 2)..(far + 2)).to_a)
  end

  it "drops what has expired per table, honouring overrides" do
    setting = AppSetting.current
    setting.update!(retention_days: { "spans" => 1, "metric_points" => 10 })
    # Three days on: spans (kept 1 day) lose everything but the newest day;
    # nothing with a longer window is touched.
    dropped = described_class.drop_expired!(today: today + 3, setting: setting)
    expect(dropped.map(&:table).uniq).to eq([ "spans" ])
    expect(dropped.map(&:day)).to eq([ today - 2, today - 1, today, today + 1 ])
  end

  it "sheds the oldest days of the most expendable signal to meet a budget" do
    shed = described_class.shed_to_budget!(budget_bytes: 0, today: today)
    expect(shed).not_to be_empty
    expect(shed.first.table).to eq("logs")
    expect(shed.first.day).to eq(today - 2)
    expect(shed.map(&:table)).not_to include("markers", "metric_points_1h")
    expect(shed.map(&:day)).not_to include(today)
  end

  it "refuses to size retention outside a table's bounds" do
    setting = AppSetting.current
    setting.retention_days = { "transactions" => 5000 }
    expect(setting).not_to be_valid
    setting.retention_days = { "nope" => 5 }
    expect(setting).not_to be_valid
  end
end
