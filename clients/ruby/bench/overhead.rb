# frozen_string_literal: true

# The agent's cost on a CPU-bound, multi-threaded workload (four threads,
# like a small Puma): the same work with the agent inert, with tracing and
# metrics only, and with continuous profiling at 100 Hz. Every unit of work
# runs inside a transaction so the profiler has intervals to attribute.
#
#   cd clients/ruby && bundle exec ruby bench/overhead.rb

require "benchmark"
require_relative "../test/test_helper"

def hot_a = 200_000.times.sum { |i| i * i }
def hot_b = 100_000.times.map { |i| i.to_s }.size

MW = Glass::Middleware.new(->(_env) { 12.times { hot_a; hot_b; sleep(0.001) }; [200, {}, []] })
ENV_TEMPLATE = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/bench", "REMOTE_ADDR" => "10.0.0.1" }.freeze

def run = 4.times.map { Thread.new { MW.call(ENV_TEMPLATE.dup) } }.each(&:join)

def configure(profiling:)
  Glass.reset!
  Glass.configure do |c|
    c.url = "http://glass.test"
    c.api_key = "bench"
    c.sender = FakeSender.new
    c.enabled[:profiling] = profiling
    c.enabled[:runtime] = false
    c.profile_window = 5
    c.profile_hz = 100
    c.flush_interval = 5
  end
  Glass.start
  sleep 1.5 if profiling # let the first window open before measuring
end

def median(a) = a.sort[a.size / 2]

3.times { run } # warm
results = Hash.new { |h, k| h[k] = [] }
6.times do
  Glass.reset!
  results[:inert] << Benchmark.realtime { run }
  configure(profiling: false)
  results[:traced] << Benchmark.realtime { run }
  configure(profiling: true)
  results[:profiled] << Benchmark.realtime { run }
end
Glass.reset!

base = median(results[:inert])
results.each do |k, v|
  m = median(v)
  puts format("%-9s median %5dms  (%+.1f%% vs inert)", k, (m * 1000).round, (m / base - 1) * 100)
end
