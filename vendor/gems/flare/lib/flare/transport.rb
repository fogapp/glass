# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module Flare
  # One background thread draining a bounded queue. The contract that makes
  # this safe to run inside every app: enqueue never blocks (overflow drops),
  # delivery failures drop (never retry into a dead server), and a 429's
  # Retry-After pauses the worker so fog can shed load with one header.
  class Transport
    attr_reader :dropped

    def initialize(config, sender: nil)
      @config = config
      @sender = sender || config.sender || HttpSender.new(config)
      @queue = SizedQueue.new(config.queue_size)
      @dropped = 0
      @mutex = Mutex.new
      @thread = nil
      @pid = nil
    end

    def enqueue(event)
      ensure_worker
      @queue.push(event, true)
    rescue ThreadError # queue full — shed, don't block the app
      @dropped += 1
      nil
    end

    def flush(timeout: 2)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.05 until @queue.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      nil
    end

    def shutdown
      @thread&.kill
      @thread = nil
    end

    private

    # Puma and Solid Queue fork; threads don't survive a fork. Rather than
    # asking every app to add an after-fork hook, detect the new pid on the
    # next enqueue and start fresh (dropping any events inherited from the
    # parent — the parent's worker owns those).
    def ensure_worker
      return if @thread&.alive? && @pid == Process.pid
      @mutex.synchronize do
        return if @thread&.alive? && @pid == Process.pid
        @queue = SizedQueue.new(@config.queue_size) if @pid && @pid != Process.pid
        @pid = Process.pid
        @thread = Thread.new { work }
        @thread.name = "flare"
      end
    end

    def work
      loop do
        event = @queue.pop
        pause = deliver(event)
        sleep([pause, 60].min) if pause&.positive?
      end
    end

    # Returns seconds to pause (server said 429), or nil.
    def deliver(event)
      @sender.call(event)
    rescue StandardError
      @dropped += 1
      nil
    end
  end

  # POSTs one event per envelope. Sized for a LAN hop to fog: short
  # timeouts, no retries, no connection pooling worth the code.
  class HttpSender
    def initialize(config)
      @config = config
    end

    def call(event)
      dsn = @config.parsed_dsn or return nil
      payload = JSON.generate(event)
      envelope = +""
      envelope << JSON.generate(event_id: event[:event_id], sent_at: Time.now.utc.iso8601) << "\n"
      envelope << JSON.generate(type: "event", length: payload.bytesize) << "\n"
      envelope << payload << "\n"

      uri = URI.parse(dsn.endpoint)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/x-sentry-envelope"
      req["X-Sentry-Auth"] =
        "Sentry sentry_version=7, sentry_client=flare-ruby/#{VERSION}, sentry_key=#{dsn.key}"
      req.body = envelope
      resp = http.request(req)
      resp.code == "429" ? (resp["Retry-After"] || "60").to_i.clamp(1, 300) : nil
    end
  end
end
