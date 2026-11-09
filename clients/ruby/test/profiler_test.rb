# frozen_string_literal: true

require_relative "test_helper"

class ProfilerTest < Minitest::Test
  include GlassTestSupport

  # A stack table shaped like Vernier's: funcs, one frame per func, stacks
  # as (frame, parent) pairs.
  class FakeStackTable
    def initialize(funcs, stacks)
      @funcs = funcs
      @stacks = stacks
    end

    def stack_frame_idx(i) = @stacks[i][0]
    def stack_parent_idx(i) = @stacks[i][1]
    def frame_func_idx(f) = f
    def frame_line_no(_f) = 0
    def func_name(f) = @funcs[f][0]
    def func_filename(f) = @funcs[f][1]
    def func_first_lineno(f) = @funcs[f][2]
  end

  FakeResult = Struct.new(:threads, :stack_table, :meta, :gc_markers)
  MS = 1_000_000 # ns

  FUNCS = [
    ["<main>", "/app/app.rb", 1],
    ["Work#run", "/app/app/services/work.rb", 12],
    ["ActiveRecord::Relation#load", "/usr/local/bundle/gems/activerecord-8.1.3.1/lib/active_record/relation.rb", 900],
    ["Array#each", "<internal:array>", 0],
    ["Kernel#sleep", "<cfunc>", 0]
  ].freeze
  # vernier stack idx: 0 main, 1 main>work, 2 A = main>work>relation, 3 B = main>work>each, 4 C = main>sleep
  STACKS = [[0, nil], [1, 0], [2, 1], [3, 1], [4, 0]].freeze
  A = 2
  B = 3
  C = 4

  def fold(threads, intervals, gc_markers: nil)
    Glass.reset!
    Glass.config.app_root = "/app"
    result = FakeResult.new(threads, FakeStackTable.new(FUNCS, STACKS), { interval: 10_000 }, gc_markers)
    Glass::Profiler::Fold.new(Glass.config).fold(result, intervals, started_wall: 1_790_000_100.0, dur: 0.2, hz: 100)
  end

  def sample_rows(rec)
    rec[:samples].map { |s, name, state, w| [rec[:stacks][s].map { |f| rec[:funcs][f][0] }, name, state, w] }
  end

  def test_folding_attributes_by_thread_interval_and_drops_idle_outside_transactions
    gc_pause = Glass::Profiler::Fold::GC_PAUSE
    threads = {
      101 => { samples: [A, B, C, A, B], weights: [3, 2, 5, 2, 1], timestamps: [0, 30 * MS, 50 * MS, 100 * MS, 140 * MS],
               sample_categories: [0, 2, 1, 0, 0] },
      202 => { samples: [C], weights: [4], timestamps: [0], sample_categories: [1] },
      303 => { samples: [C, A], weights: [3, 1], timestamps: [0, 30 * MS], sample_categories: [1, 0] }
    }
    intervals = [
      [101, 0.015, 0.045, "Wants#index"],
      [101, 0.095, 0.200, "SearchPlanJob"],
      [202, 0.0, nil, "Long#req"] # still running at the window's end
    ]
    markers = [[gc_pause, 1, 110 * MS, 130 * MS, nil, {}], [3, 0, 5 * MS, 5 * MS, nil, {}]]
    rec = fold(threads, intervals, gc_markers: markers)

    assert_equal "profile", rec[:t]
    assert_equal [1_790_000_100.0, 0.2, 100, "wall"], rec.values_at(:ts, :dur, :hz, :mode)
    rows = sample_rows(rec)
    a = ["<main>", "Work#run", "ActiveRecord::Relation#load"]
    b = ["<main>", "Work#run", "Array#each"]
    c = ["<main>", "Kernel#sleep"]
    expected = [
      [a, nil, "running", 3], # thread 101's first two ticks plus thread 303's one, folded
      [a, "Wants#index", "running", 1],
      [b, "Wants#index", "stalled", 2],
      [a, "SearchPlanJob", "running", 2], [a, "SearchPlanJob", "gc", 2], [b, "SearchPlanJob", "running", 1],
      [c, "Long#req", "idle", 4]
    ]
    expected.each { |row| assert_includes rows, row }
    assert_equal expected.size, rows.size, "idle samples outside any transaction are not sent: #{rows.inspect}"
    assert rec[:stacks].all? { |s| rec[:funcs][s.first][0] == "<main>" }, "stacks are root first"
  end

  def test_funcs_carry_relative_paths_and_categories
    rec = fold({ 1 => { samples: [A, B, C], weights: [1, 1, 1], timestamps: [0, 10 * MS, 20 * MS], sample_categories: [0, 0, 0] } }, [])
    funcs = rec[:funcs].to_h { |name, file, line, cat| [name, [file, line, cat]] }
    assert_equal ["app.rb", 1, "app"], funcs["<main>"]
    assert_equal ["app/services/work.rb", 12, "app"], funcs["Work#run"]
    assert_equal ["activerecord/lib/active_record/relation.rb", 900, "gem"], funcs["ActiveRecord::Relation#load"]
    assert_equal ["<internal:array>", 0, "ruby"], funcs["Array#each"]
    assert_equal ["<cfunc>", 0, "native"], funcs["Kernel#sleep"]
    rec[:funcs].each { |_, file, _, _| refute file.start_with?("/"), "never an absolute path: #{file}" }
  end

  def test_paths_strip_gem_versions_and_ruby_dirs
    paths = Glass::Profiler::Paths.new("/srv/app")
    assert_equal ["nokogiri/lib/nokogiri.rb", "gem"], paths.classify("/usr/local/bundle/gems/nokogiri-1.16.0-aarch64-linux/lib/nokogiri.rb")
    assert_equal ["rails/activesupport/lib/x.rb", "gem"], paths.classify("/usr/local/bundle/bundler/gems/rails-3df7786abcde/activesupport/lib/x.rb")
    assert_equal ["flare/lib/flare.rb", "gem"], paths.classify("/srv/app/vendor/gems/flare/lib/flare.rb")
    assert_equal ["net/http.rb", "ruby"], paths.classify(File.join(RbConfig::CONFIG["rubylibdir"], "net/http.rb"))
    assert_equal ["glass/lib/glass/transport.rb", "gem"], paths.classify(File.expand_path("../lib/glass/transport.rb", __dir__))
    assert_equal ["puma/lib/puma/server.rb", "gem"], paths.classify("/Users/x/.rbenv/versions/3.4.2/lib/ruby/gems/3.4.0/gems/puma-8.0.2/lib/puma/server.rb")
    assert_equal ["c/d/e.rb", "gem"], paths.classify("/a/b/c/d/e.rb")
    assert_equal ["(eval)", "app"], paths.classify("(eval at /srv/app/x.rb:3)")
  end

  def test_run_length_encoded_samples_split_across_interval_boundaries
    # One entry of weight 10 at t=0 spanning 100ms; the transaction covers 35..75ms.
    threads = { 1 => { samples: [A], weights: [10], timestamps: [0], sample_categories: [0] } }
    rec = fold(threads, [[1, 0.035, 0.075, "X#y"]])
    rows = sample_rows(rec).map { |_, name, state, w| [name, state, w] }
    assert_includes rows, [nil, "running", 6]      # ticks 0,10,20,30 and 80,90
    assert_includes rows, ["X#y", "running", 4]    # ticks 40,50,60,70
    assert_equal 10, rows.sum(&:last)
  end

  def test_record_is_capped_at_max_stacks_with_a_truncated_frame
    n = Glass::Profiler::MAX_STACKS + 20
    funcs = [["<main>", "/app/a.rb", 1]] + (0...n).map { |i| ["f#{i}", "/app/f.rb", i] }
    stacks = [[0, nil]] + (0...n).map { |i| [i + 1, 0] }
    Glass.reset!
    Glass.config.app_root = "/app"
    threads = { 1 => { samples: (1..n).to_a, weights: (1..n).to_a, timestamps: (0...n).map { |i| i * MS }, sample_categories: [0] * n } }
    result = FakeResult.new(threads, FakeStackTable.new(funcs, stacks), { interval: 1_000 }, nil)
    rec = Glass::Profiler::Fold.new(Glass.config).fold(result, [], started_wall: 0.0, dur: 1.0, hz: 1000)
    assert_equal Glass::Profiler::MAX_STACKS + 1, rec[:stacks].size
    trunc = rec[:funcs].index { |f| f[0] == "(truncated)" }
    refute_nil trunc
    trunc_row = rec[:samples].find { |s, _, _, _| rec[:stacks][s] == [trunc] }
    assert_equal (1..20).sum, trunc_row[3], "the lightest stacks fold into the truncated frame"
  end

  def test_real_vernier_window_attributes_a_hot_method_to_its_transaction
    begin
      require "vernier"
    rescue LoadError
      skip "vernier not available"
    end
    Glass.reset!
    Glass.config.app_root = File.expand_path("..", __dir__)
    profiler = Glass::Profiler.new(Glass.config, Glass::Tracer.intervals)
    collector = ::Vernier::Collector.new(:wall, interval: 5_000)
    collector.start
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    worker = Thread.new do
      Thread.current.name = "fake-request"
      sleep 0.05 # idle, outside any transaction: must be dropped
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ProfilerTest.hot_method until Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 > 0.25
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      [t0, t1]
    end
    t0, t1 = worker.value
    result = collector.stop
    intervals = [[worker.object_id, t0, t1, "Fake#show"]]
    rec = Glass::Profiler::Fold.new(Glass.config).fold(result, intervals, started_wall: Time.now.to_f, dur: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, hz: 200)
    refute_nil rec
    by_name = Hash.new(0)
    hot = 0
    rec[:samples].each do |s, name, state, w|
      by_name[[name, state]] += w
      hot += w if name == "Fake#show" && rec[:stacks][s].any? { |f| rec[:funcs][f][0] == "ProfilerTest.hot_method" }
    end
    total = by_name[["Fake#show", "running"]] + by_name[["Fake#show", "stalled"]]
    assert_operator total, :>=, 20, "a 250ms transaction at 200Hz yields dozens of samples: #{by_name.inspect}"
    assert_operator hot.to_f / total, :>=, 0.9, "the hot method dominates the transaction's samples"
    assert_equal 0, by_name[[nil, "idle"]], "the idle wait before the transaction is dropped"
    func = rec[:funcs].find { |f| f[0] == "ProfilerTest.hot_method" }
    assert_equal ["glass/test/profiler_test.rb", "gem"], [func[1], func[3]], "the agent's own tree is a gem, wherever it sits"
    assert_kind_of Integer, func[2]
    JSON.generate(rec) # serializable
  ensure
    profiler&.shutdown
  end

  def self.hot_method
    x = 0
    20_000.times { |i| x += i * i }
    x
  end

  def test_profile_now_runs_once_per_id_and_tags_the_record
    begin
      require "vernier"
    rescue LoadError
      skip "vernier not available"
    end
    Glass.reset!
    Glass.config.profiling = false # the directive is off: profile_now still runs
    profiler = Glass::Profiler.new(Glass.config, Glass::Tracer.intervals)
    Glass.config.enabled[:profiling] = false # the local kill switch blocks even a one-shot
    profiler.request({ "id" => "blocked", "seconds" => 1, "hz" => 200 })
    assert_empty profiler.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
    refute profiler.running?
    Glass.config.enabled[:profiling] = true
    profiler.request({ "id" => "req-1", "seconds" => 1, "hz" => 200 })
    profiler.request({ "id" => "req-1", "seconds" => 1, "hz" => 200 })
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_empty profiler.tick(now)
    assert profiler.running?
    assert_in_delta now + 1.0, profiler.deadline, 0.01
    ProfilerTest.hot_method while Process.clock_gettime(Process::CLOCK_MONOTONIC) < now + 0.2
    records = profiler.tick(now + 1.0)
    assert_equal 1, records.size
    assert_equal "req-1", records.first[:request]
    assert_equal 200, records.first[:hz]
    refute profiler.running?, "with profiling off, no continuous window follows"
    assert_empty profiler.tick(now + 2.0)
  ensure
    profiler&.shutdown
  end

  def test_no_collector_crosses_a_fork
    begin
      require "vernier"
    rescue LoadError
      skip "vernier not available"
    end
    skip "no fork" unless Process.respond_to?(:fork)
    sender = configure_glass
    Glass.config.enabled[:profiling] = true
    Glass.config.profile_window = 30
    Glass.start
    profiler = Glass.transport.profiler
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.05 until profiler.running? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert profiler.running?, "test premise: a window is open in the parent"
    r, w = IO.pipe
    pid = fork do
      r.close
      # The child inherits nothing running; its own agent starts clean and
      # can open a window of its own.
      state = { running_at_fork: profiler.running?, agent_alive: Glass.transport.running? }
      records = profiler.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      state[:opened] = profiler.running?
      state[:records] = records.size
      profiler.shutdown
      w.write(JSON.generate(state))
      w.close
      exit!(0)
    end
    w.close
    child = JSON.parse(r.read)
    Process.wait(pid)
    assert_equal false, child["running_at_fork"], "the parent stopped its window before forking"
    assert child["agent_alive"], "the child restarted the agent thread"
    assert child["opened"], "and can profile on its own"
    refute profiler.running?, "the parent's window was stopped by the fork hook"
    profiler.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
    assert profiler.running?, "and the parent opens a new one on its next tick"
    refute_nil sender
  end

  def test_skips_quietly_when_another_vernier_profile_is_running
    begin
      require "vernier"
    rescue LoadError
      skip "vernier not available"
    end
    Glass.reset!
    profiler = Glass::Profiler.new(Glass.config, Glass::Tracer.intervals)
    ::Vernier.start_profile(mode: :wall, interval: 10_000)
    begin
      assert_empty profiler.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      refute profiler.running?
    ensure
      ::Vernier.stop_profile
    end
    profiler.tick(Process.clock_gettime(Process::CLOCK_MONOTONIC))
    assert profiler.running?, "and resumes once it is gone"
  ensure
    profiler&.shutdown
  end
end
