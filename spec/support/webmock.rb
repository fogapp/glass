# typed: false
# frozen_string_literal: true

require "webmock/rspec"

# No real network in specs, ever.
WebMock.disable_net_connect!(allow_localhost: false)

# The address guard fails closed on unresolvable names, and spec hostnames
# (big.test, feeds.example.test) are unresolvable on purpose. Stub resolution
# to a public documentation address so WebMock-stubbed fetches pass the guard;
# guard specs re-stub `resolve` themselves to exercise the real logic.
RSpec.configure do |config|
  config.before do
    # The guard memoizes resolutions process-locally for 60s — longer than a
    # spec run, so answers would bleed between examples without this.
    UpstreamAddressGuard.instance_variable_get(:@resolutions).clear
    allow(UpstreamAddressGuard).to receive(:resolve).and_return([ "203.0.113.7" ])
  end
end
