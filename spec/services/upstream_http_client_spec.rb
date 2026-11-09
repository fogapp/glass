# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe UpstreamHttpClient do
  # A minimal includer, so these test the module rather than whichever
  # connector happens to exercise it.
  boom = Class.new(UpstreamHttpClient::Error)
  before { stub_const("Boom", boom) }

  let(:client_class) do
    Class.new do
      include UpstreamHttpClient

      def service_name = "the test host"
      def error_class = Boom
    end
  end
  let(:client) { client_class.new }

  describe "connection errors" do
    it "marks can't-reach failures so callers can be patient; HTTP status errors are not" do
      stub_request(:get, "https://down.test/feed").to_timeout

      expect { client.http_json(:get, "https://down.test/feed") }
        .to raise_error(Boom) { |e| expect(e.connection?).to be(true) }

      stub_request(:get, "https://up.test/feed").to_return(status: 500, body: "")
      expect { client.http_json(:get, "https://up.test/feed") }
        .to raise_error(Boom) { |e| expect(e.connection?).to be(false) }
    end

    it "marks the breaker's own refusal as a connection error too" do
      stub_request(:get, "https://flaky.test/feed").to_timeout
      UpstreamCircuitBreaker::THRESHOLD.times do
        expect { client.http_json(:get, "https://flaky.test/feed") }.to raise_error(Boom)
      end

      expect { client.http_json(:get, "https://flaky.test/feed") }
        .to raise_error(Boom, /unreachable/) { |e| expect(e.connection?).to be(true) }
    end
  end

  describe "body caps" do
    # Net::HTTP's ordinary form buffers the whole response before anyone can
    # object to its size, so a cap applied afterwards caps what we keep rather
    # than what we take.
    it "refuses a response past the cap instead of taking it all first" do
      stub_request(:get, "https://big.test/feed").to_return(status: 200, body: "x" * 5_000)

      expect { client.http_json(:get, "https://big.test/feed", max_bytes: 1_000) }
        .to raise_error(Boom, /exceeds the 1000-byte cap/)
    end

    it "accepts a response inside the cap" do
      stub_request(:get, "https://ok.test/feed").to_return(status: 200, body: "hello")

      expect(client.http_json(:get, "https://ok.test/feed", max_bytes: 1_000).body).to eq("hello")
    end

    # Error branches never use their body, but Net::HTTP buffers whatever the
    # block leaves — a hostile 500 can carry gigabytes as easily as a 200 can.
    it "reports an oversized error response by its status, without buffering it" do
      stub_request(:get, "https://angry.test/feed")
        .to_return(status: 500, body: "x" * (described_class::ERROR_BODY_ALLOWANCE * 3))

      expect { client.http_json(:get, "https://angry.test/feed") }
        .to raise_error(Boom, /returned 500/)
    end

    it "caps what a POST takes, not just what it keeps" do
      stub_request(:post, "https://verbose.test/api").to_return(status: 200, body: "y" * 5_000)

      expect { client.http_post_json("https://verbose.test/api", body: {}, max_bytes: 1_000) }
        .to raise_error(Boom, /exceeds the 1000-byte cap/)
    end

    # Ratios above 1000:1 are trivial to produce, so a cap on the wire says
    # nothing about what the bytes become once expanded.
    it "stops inflating a gzip bomb rather than expanding it into memory" do
      bomb = StringIO.new.tap do |io|
        writer = Zlib::GzipWriter.new(io)
        writer.write("a" * 5_000_000)
        writer.close
      end.string
      stub_request(:get, "https://bomb.test/feed").to_return(
        status: 200, body: bomb, headers: { "Content-Encoding" => "gzip" }
      )

      expect { client.http_json(:get, "https://bomb.test/feed", max_bytes: 10_000) }
        .to raise_error(Boom, /expands past the 10000-byte cap/)
    end

    it "still decompresses an ordinary gzipped body" do
      gzipped = StringIO.new.tap do |io|
        writer = Zlib::GzipWriter.new(io)
        writer.write("<feed/>")
        writer.close
      end.string
      stub_request(:get, "https://gz.test/feed").to_return(
        status: 200, body: gzipped, headers: { "Content-Encoding" => "gzip" }
      )

      expect(client.http_json(:get, "https://gz.test/feed").body).to eq("<feed/>")
    end

    it "hands back a body whose gzip header was a lie rather than failing on it" do
      stub_request(:get, "https://liar.test/feed").to_return(
        status: 200, body: "not actually gzip", headers: { "Content-Encoding" => "gzip" }
      )

      expect(client.http_json(:get, "https://liar.test/feed").body).to eq("not actually gzip")
    end
  end

  # An upstream that refuses a request usually says why, in the body nobody
  # was reading. "rejected our credentials" sends an operator to re-check a
  # password that was never wrong; "Missing permission: library_upload"
  # names the fix.
  describe "what the upstream said" do
    it "repeats a JSON message on a refusal" do
      stub_request(:get, "https://api.test/thing")
        .to_return(status: 403, body: '{"statusCode":403,"message":"Missing permission: library_upload"}',
          headers: { "Content-Type" => "application/json" })

      expect { client.http_json(:get, "https://api.test/thing") }
        .to raise_error(UpstreamHttpClient::AuthError, /Missing permission: library_upload/)
    end

    it "joins the list of field errors a validating API sends" do
      stub_request(:patch, "https://api.test/thing")
        .to_return(status: 400, body: '{"message":["seriesIndex must be a number","title should not be empty"]}',
          headers: { "Content-Type" => "application/json" })

      expect { client.http_json(:patch, "https://api.test/thing", body: {}) }
        .to raise_error(Boom, /seriesIndex must be a number; title should not be empty/)
    end

    it "keeps the detail on the error for a caller that wants to rephrase it" do
      stub_request(:get, "https://api.test/thing")
        .to_return(status: 403, body: '{"message":"nope"}', headers: { "Content-Type" => "application/json" })

      client.http_json(:get, "https://api.test/thing")
    rescue UpstreamHttpClient::AuthError => e
      expect(e.detail).to eq("nope")
      expect(e.status).to eq(403)
    end

    # An HTML error page explains nothing and would push the real status off
    # the end of a notification.
    it "does not quote an HTML error page" do
      stub_request(:get, "https://api.test/thing")
        .to_return(status: 502, body: "<html><body>Bad Gateway</body></html>",
          headers: { "Content-Type" => "text/html" })

      expect { client.http_json(:get, "https://api.test/thing") }
        .to raise_error(Boom, /\Athe test host returned 502\z/)
    end

    it "truncates a talkative upstream" do
      stub_request(:get, "https://api.test/thing")
        .to_return(status: 500, body: { message: "z" * 2_000 }.to_json,
          headers: { "Content-Type" => "application/json" })

      expect { client.http_json(:get, "https://api.test/thing") }
        .to raise_error(Boom) { |e| expect(e.detail.length).to be <= described_class::DETAIL_LIMIT }
    end
  end

  describe "the body deadline" do
    # read_timeout bounds each individual read; only the deadline bounds their
    # sum — a host trickling one byte per read never times out without it.
    it "abandons a body that is still arriving past the wall-clock budget" do
      dribble = double("response")
      allow(dribble).to receive(:read_body) do |&blk|
        3.times { blk.call("x") }
      end
      # First call establishes the deadline; the next lands past it.
      allow(Process).to receive(:clock_gettime)
        .and_return(0.0, client.body_deadline + 1.0)

      expect { client.send(:read_capped, dribble, 1_000) }
        .to raise_error(UpstreamHttpClient::DeadlineExceeded, /still arriving/)
    end

    it "drains error bodies under the same budget" do
      dribble = double("response")
      allow(dribble).to receive(:read_body) do |&blk|
        3.times { blk.call("x") }
      end
      allow(Process).to receive(:clock_gettime)
        .and_return(0.0, client.body_deadline + 1.0)

      expect { client.send(:drain_capped, dribble) }
        .to raise_error(UpstreamHttpClient::DeadlineExceeded)
    end

    it "counts a dribbling host against the circuit breaker like any network failure" do
      stub_request(:get, "https://drip.test/feed").to_return(status: 200, body: "x")
      allow(client).to receive(:read_capped)
        .and_raise(UpstreamHttpClient::DeadlineExceeded, "drip")

      expect(UpstreamCircuitBreaker).to receive(:trip!).with("the test host:drip.test")
      expect { client.http_json(:get, "https://drip.test/feed") }
        .to raise_error(Boom, /Could not reach/)
    end
  end

  describe "the private-address guard" do
    it "refuses an address on this machine's own network" do
      expect { client.http_json(:get, "http://127.0.0.1:5432/") }
        .to raise_error(Boom, /own network/)
    end

    it "refuses the cloud metadata endpoint by name and by number" do
      expect { client.http_json(:get, "http://169.254.169.254/latest/meta-data/") }
        .to raise_error(Boom, /own network/)
    end

    it "refuses a private range" do
      expect { client.http_json(:get, "http://192.168.1.1/admin") }
        .to raise_error(Boom, /own network/)
    end

    it "refuses a scheme that isn't HTTP" do
      expect { client.http_json(:get, "file:///etc/passwd") }
        .to raise_error(Boom, /not a scheme Glass will fetch/)
    end

    it "refuses a private address on a JSON write too" do
      expect { client.http_json(:patch, "http://10.0.0.5/api/thing", body: { a: 1 }) }
        .to raise_error(Boom, /own network/)
    end

    it "leaves public addresses alone" do
      stub_request(:get, "https://public.test/feed").to_return(status: 200, body: "ok")

      expect(client.http_json(:get, "https://public.test/feed").body).to eq("ok")
    end

    # A name that cannot be resolved cannot be vetted; letting it through
    # would hand the decision to whatever resolver answers the actual connect.
    it "fails closed when the name does not resolve" do
      allow(UpstreamAddressGuard).to receive(:resolve).and_return([])

      expect { client.http_json(:get, "https://ghost.test/feed") }
        .to raise_error(Boom, /did not resolve/)
    end

    # Pinning is what makes the guard real: connecting by name would resolve
    # a second time, and a name that answers differently between the check and
    # the connect (DNS rebinding) would walk right past it.
    it "pins the connection to the address it vetted" do
      stub_request(:get, "https://pinned.test/feed").to_return(status: 200, body: "ok")
      expect(Net::HTTP).to receive(:start)
        .with("pinned.test", 443, hash_including(ipaddr: "203.0.113.7"))
        .and_call_original

      client.http_json(:get, "https://pinned.test/feed")
    end

    # ntfy and fog live on private addresses by design, so this is a
    # per-caller decision rather than a rule.
    it "lets a client that opted in reach a local endpoint" do
      local = Class.new(client_class) do
        def allow_private_addresses? = true
      end
      stub_request(:post, "http://127.0.0.1:8080/jsonrpc")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      expect(local.new.http_post_json("http://127.0.0.1:8080/jsonrpc", body: {}).status)
        .to eq(200)
    end

    it "does not follow a redirect" do
      local = Class.new(client_class) { def allow_private_addresses? = true }
      stub_request(:post, "http://127.0.0.1:8080/api")
        .to_return(status: 302, headers: { "Location" => "http://127.0.0.1:8080/elsewhere" })

      expect { local.new.http_post_json("http://127.0.0.1:8080/api", body: {}) }
        .to raise_error(Boom, /too many redirects/)
    end
  end

  describe UpstreamHttpClient::Response do
    let(:typed) { Class.new(UpstreamHttpClient::Error) }

    def response(body) = described_class.new(status: 200, body: body, url: "http://x.test")

    it "parses JSON of any shape with json!" do
      expect(response('[1, 2]').json!(typed, "Svc")).to eq([ 1, 2 ])
      expect(response('{"a": 1}').json!(typed, "Svc")).to eq({ "a" => 1 })
    end

    it "raises the client's own error, with any hint, when the body is not JSON" do
      expect { response("<html>").json!(typed, "Svc", hint: "check the URL") }
        .to raise_error(typed, "Svc answered with something that wasn't JSON — check the URL")
    end

    it "insists on an object with json_object!" do
      expect(response('{"a": 1}').json_object!(typed, "Svc")).to eq({ "a" => 1 })
      expect { response("[]").json_object!(typed, "Svc") }.to raise_error(typed, "Svc answered with Array, not an object")
      expect { response("nope").json_object!(typed, "Svc") }.to raise_error(typed, /wasn't JSON/)
    end
  end
end
