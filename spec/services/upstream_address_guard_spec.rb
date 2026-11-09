# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe UpstreamAddressGuard do
  # The global webmock support glass stubs `resolve` (spec hostnames are
  # unresolvable on purpose); these specs re-stub it per-example to exercise
  # the guard's own logic.
  def resolving(host, to:)
    allow(described_class).to receive(:resolve).with(host).and_return(Array(to))
  end

  describe "scheme handling" do
    it "refuses non-http(s) schemes" do
      %w[ftp://host/x file:///etc/passwd gopher://host ldap://host].each do |url|
        expect { described_class.check!(url, service_name: "Test") }
          .to raise_error(described_class::Blocked, /not a scheme Glass will fetch/)
      end
    end

    it "refuses a URL with no host" do
      expect { described_class.check!("https:///path", service_name: "Test") }
        .to raise_error(described_class::Blocked, /no host/)
    end

    it "refuses garbage it cannot parse" do
      expect { described_class.check!("http://[bad", service_name: "Test") }
        .to raise_error(described_class::Blocked, /isn't a URL/)
    end
  end

  describe "literal-address hosts" do
    blocked_literals = %w[
      0.0.0.0 10.1.2.3 127.0.0.1 127.8.8.8 169.254.169.254 172.16.0.1
      172.31.255.255 192.0.0.10 192.168.1.1 198.18.0.5 224.0.0.1 240.0.0.1
    ]

    blocked_literals.each do |address|
      it "blocks #{address}" do
        expect { described_class.check!("http://#{address}/", service_name: "Test") }
          .to raise_error(described_class::Blocked, /own network/)
      end
    end

    it "blocks IPv6 loopback, link-local, unique-local, and multicast" do
      %w[::1 fe80::1 fc00::1 fd12:3456::1 ff02::1].each do |address|
        expect { described_class.check!("http://[#{address}]/", service_name: "Test") }
          .to raise_error(described_class::Blocked, /own network/)
      end
    end

    it "allows public literals and returns them for pinning" do
      expect(described_class.check!("https://93.184.216.34/feed", service_name: "Test"))
        .to eq("93.184.216.34")
      expect(described_class.check!("https://[2606:4700::1111]/feed", service_name: "Test"))
        .to eq("2606:4700::1111")
    end
  end

  describe "resolved hosts" do
    it "blocks a name that resolves to a private address" do
      resolving("evil.test", to: "10.0.0.5")

      expect { described_class.check!("https://evil.test/feed", service_name: "Test") }
        .to raise_error(described_class::Blocked, /10\.0\.0\.5/)
    end

    it "blocks a name where any one answer is private" do
      resolving("mixed.test", to: [ "93.184.216.34", "169.254.169.254" ])

      expect { described_class.check!("https://mixed.test/feed", service_name: "Test") }
        .to raise_error(described_class::Blocked, /169\.254\.169\.254/)
    end

    it "fails closed when the name does not resolve" do
      resolving("ghost.test", to: [])

      expect { described_class.check!("https://ghost.test/feed", service_name: "Test") }
        .to raise_error(described_class::Blocked, /did not resolve/)
    end

    it "returns a public answer for pinning, preferring IPv4" do
      resolving("dual.test", to: [ "2606:4700::1111", "93.184.216.34" ])

      expect(described_class.check!("https://dual.test/feed", service_name: "Test"))
        .to eq("93.184.216.34")
    end

    it "returns an IPv6 answer when that is all there is" do
      resolving("v6only.test", to: "2606:4700::1111")

      expect(described_class.check!("https://v6only.test/feed", service_name: "Test"))
        .to eq("2606:4700::1111")
    end
  end

  # A resolver blip is not evidence the host moved: production spent an
  # evening failing "huggingface.co did not resolve" for a host it resolves
  # all day. The last vetted answer keeps serving for a bounded window.
  describe "stale-serve when the resolver goes dark" do
    # Rewinds a cache entry's timestamp; the guard keys freshness off a
    # monotonic clock, which travel_to cannot move.
    def age_cache(host, by:)
      cache = described_class.instance_variable_get(:@resolutions)
      stamped, addresses = cache.fetch(host)
      cache[host] = [ stamped - by, addresses ]
    end

    it "serves the last vetted answer while inside the stale window" do
      resolving("flaky.test", to: "93.184.216.34")
      described_class.check!("https://flaky.test/feed", service_name: "Test")

      resolving("flaky.test", to: [])
      age_cache("flaky.test", by: described_class::RESOLUTION_TTL + 1)

      expect(described_class.check!("https://flaky.test/feed", service_name: "Test"))
        .to eq("93.184.216.34")
    end

    it "fails closed again once the host has been dark past the window" do
      resolving("gone-dark.test", to: "93.184.216.34")
      described_class.check!("https://gone-dark.test/feed", service_name: "Test")

      resolving("gone-dark.test", to: [])
      age_cache("gone-dark.test", by: described_class::STALE_RESOLUTION_TTL + 1)

      expect { described_class.check!("https://gone-dark.test/feed", service_name: "Test") }
        .to raise_error(described_class::Blocked, /did not resolve/)
    end

    it "still blocks a stale-served answer that is private — every call re-vets" do
      resolving("stale-evil.test", to: "10.0.0.5")
      expect { described_class.check!("https://stale-evil.test/feed", service_name: "Test") }
        .to raise_error(described_class::Blocked, /own network/)

      resolving("stale-evil.test", to: [])
      age_cache("stale-evil.test", by: described_class::RESOLUTION_TTL + 1)

      expect { described_class.check!("https://stale-evil.test/feed", service_name: "Test") }
        .to raise_error(described_class::Blocked, /own network/)
    end
  end
end
