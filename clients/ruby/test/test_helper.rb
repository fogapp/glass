# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "zlib"
require_relative "../lib/glass"

# A sender that records instead of POSTing. Each call captures the gzipped
# body and answers with the canned status; `batches` gives the parsed
# NDJSON back (header first) so tests assert on what would go on the wire.
class FakeSender
  attr_reader :bodies, :times

  def initialize(status: 202, body: '{"accepted":1,"skipped":0,"directives":{}}', retry_after: nil)
    @status = status
    @body = body
    @retry_after = retry_after
    @bodies = []
    @times = []
    @mutex = Mutex.new
  end

  def call(body)
    @mutex.synchronize do
      @bodies << body
      @times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    Glass::Transport::Response.new(@status, @body, @retry_after)
  end

  def respond_with(status:, body: "{}", retry_after: nil)
    @status = status
    @body = body
    @retry_after = retry_after
  end

  # Parsed lines of every body sent, as one array of arrays.
  def batches
    @mutex.synchronize { @bodies.map { |b| Zlib.gunzip(b).each_line(chomp: true).map { |l| JSON.parse(l) } } }
  end

  def records(type = nil)
    all = batches.flat_map { |lines| lines.drop(1) }
    type ? all.select { |r| r["t"] == type } : all
  end
end

module GlassTestSupport
  # A configured, fake-sending Glass for one test. Returns the sender.
  def configure_glass(status: 202, **opts)
    Glass.reset!
    sender = FakeSender.new(status: status)
    Glass.configure do |c|
      c.url = "http://glass.test"
      c.api_key = "glass_ing_test"
      c.sender = sender
      c.enabled[:profiling] = false
      c.enabled[:runtime] = false
      opts.each { |k, v| c.public_send("#{k}=", v) }
    end
    sender
  end

  def teardown
    Glass.reset!
    super
  end
end
