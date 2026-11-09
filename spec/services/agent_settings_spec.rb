# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentSettings do
  describe ".coerce_overrides" do
    it "keeps only declared settings, in their types and ranges" do
      coerced = described_class.coerce_overrides(
        "trace_sample_rate" => "2", "profile_hz" => "5", "profiling" => "false", "browser" => "1",
        "log_level" => "warn", "colour" => "blue"
      )
      expect(coerced).to eq("trace_sample_rate" => 1.0, "profile_hz" => 10, "profiling" => false, "browser" => true,
        "log_level" => "warn")
    end

    it "leaves out a value that cannot be the setting, rather than storing it" do
      coerced = described_class.coerce_overrides("log_level" => "loud", "trace_sample_rate" => "abc", "profile_hz" => "")
      expect(coerced).to eq({})
    end

    it "bounds each number by its own setting's range, not by its type" do
      expect(described_class.coerce_overrides("trace_sample_rate" => -1, "profile_hz" => 5000))
        .to eq("trace_sample_rate" => 0.0, "profile_hz" => 1000)
    end

    it "reads back as what was stored" do
      coerced = described_class.coerce_overrides("trace_sample_rate" => 0.25, "profile_hz" => 250, "log_level" => "debug")
      expect(described_class.from_overrides(coerced).to_h).to include(coerced)
    end
  end

  describe ".from_overrides" do
    it "is the coerced overrides over the defaults" do
      settings = described_class.from_overrides("profile_hz" => 5, "log_level" => "loud", "browser" => false)
      expect(settings.to_h).to eq(described_class.new.to_h.merge("profile_hz" => 10, "browser" => false))
    end
  end
end
