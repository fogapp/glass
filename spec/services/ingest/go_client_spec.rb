# typed: false
# frozen_string_literal: true

require "rails_helper"
require "open3"

# The Go client and the server, actually meeting: a batch built by
# clients/go (testdata/emit) is read by the real builders and written to the
# real tables. Everything else tests one side against the conformance kit;
# this is what would catch the two sides agreeing with the kit and not with
# each other.
RSpec.describe "The Go client's batches" do
  go = %w[go /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go].find { |bin| system("#{bin} version >/dev/null 2>&1") }

  let(:household) { create_household }
  let(:reporting_app) { create_app(household: household, slug: "fog") }

  it "are read whole by the server, with nothing skipped", skip: (go ? false : "needs Go on the PATH to build clients/go") do
    body, error, status = Open3.capture3(go, "run", "./testdata/emit", chdir: Rails.root.join("clients/go").to_s)
    expect(status).to be_success, error

    result = Ingest::Receiver.call(key: ingest_key_for(reporting_app).record, text: body)
    expect(result).to have_attributes(accepted: 9, skipped: 0, skewed: 0)
    id = reporting_app.telemetry_id

    request = Telemetry::Transaction.find_by(app_id: id, kind: "request")
    expect(request).to have_attributes(
      name: "GET /api/apps/{name}", route: "/api/apps/{name}", path: "/api/apps/manor", method: "GET", http_status: 200,
      origin: "vpn", process: "web", release: "5cec02a", status: "ok", kept: true
    )
    job = Telemetry::Transaction.find_by(app_id: id, kind: "job")
    expect(job).to have_attributes(name: "backup", status: "error", error_class: "error", kept: true)

    spans = Telemetry::Span.where(app_id: id)
    expect(spans.pluck(:kind)).to contain_exactly("sql", "custom")
    expect(spans.find_by(kind: "sql").parent_id).to eq(request.span_id)

    line = Telemetry::LogLine.find_by(app_id: id)
    expect(line).to have_attributes(level: "info", message: "loaded app", source: "app", trace_id: request.trace_id)
    expect(line.attrs).to eq("app" => "manor", "password" => "[FILTERED]")

    call = Telemetry::ModelCall.find_by(app_id: id)
    expect(call).to have_attributes(provider: "llama.cpp", model: "qwen3:8b", purpose: "title", origin: "internal",
      tokens_in: 900, cost_source: "free", trace_id: request.trace_id)

    names = Telemetry::MetricSeries.where(app_id: id).pluck(:name)
    expect(names).to include("jobs.done", "go.goroutines", "fog.backup.ms")
    expect(Telemetry::AgentProcess.find_by(app_id: id).runtime).to include("client" => "glass-go", "agent" => "0.1.0", "go" => be_present)
  end
end
