# frozen_string_literal: true

module Glass
  # Always-on profiling in windows: Vernier samples every
  # thread at profile_hz for profile_window seconds; at the end of a window
  # the samples are attributed to the transactions that were running on
  # their threads, folded to (stack, transaction, state) → weight, and sent
  # as one `profile` record. Windows run back to back from the agent thread.
  #
  # Vernier is loaded lazily and only if profiling is on; if it cannot be
  # loaded the agent runs without profiles. The collector is Vernier's
  # Collector directly, not the Vernier.start_profile singleton: a developer
  # calling Vernier.start_profile in a console would otherwise find it
  # already taken (and stop ours). When that singleton is in use, a window
  # is skipped quietly.
  #
  # Fork safety: no collector may be running across a fork — its sampler
  # pthread does not exist in the child while its hooks and mutexes do. The
  # parent stops the window in Glass's Process._fork hook and the child
  # starts clean (see Glass::ForkHook).
  class Profiler
    MAX_STACKS = 5_000
    MAX_HANDLED = 50
    STATES = { 0 => "running", 1 => "idle", 2 => "stalled" }.freeze
    TRUNCATED = ["(truncated)", "", 0, "app"].freeze

    Window = Struct.new(:collector, :started_wall, :started_mono, :deadline, :hz, :request_id)

    def initialize(config, intervals)
      @config = config
      @intervals = intervals
      @lock = Mutex.new
      @window = nil
      @pending = nil # a profile_now request waiting to run
      @handled = []  # profile_now ids already served
      @unavailable = false
    end

    # Called from the agent loop: closes a window that is due, starts the
    # next one. Returns the profile records produced (0 or 1).
    def tick(now)
      records = []
      @lock.synchronize do
        if @window && now >= @window.deadline
          rec = close_window
          records << rec if rec
        end
        if @window.nil? && (@pending || @config.profiling_active?)
          open_window(now)
        elsif @window && @pending && @window.request_id.nil?
          # A one-shot request cuts the continuous window short.
          rec = close_window
          records << rec if rec
          open_window(now)
        end
      end
      records
    rescue StandardError => e
      Glass.error("profiler", e)
      records
    end

    def deadline
      @window&.deadline
    end

    # profile_now: run once per id, at the requested rate and length.
    def request(directive)
      id = directive["id"].to_s
      return if id.empty? || @handled.include?(id) || !@config.feature?(:profiling)
      @handled << id
      @handled.shift while @handled.size > MAX_HANDLED
      seconds = directive["seconds"].is_a?(Numeric) ? directive["seconds"].to_f.clamp(1, 300) : 30.0
      hz = directive["hz"].is_a?(Numeric) ? directive["hz"].to_i.clamp(10, 1_000) : @config.profile_hz
      @pending = { id: id, seconds: seconds, hz: hz }
    end

    def before_fork
      @lock.synchronize do
        next unless @window
        # The partial window is folded in the parent later would need the
        # collector alive; stop and discard — a fork is rare and the next
        # window starts at once.
        stop_collector(@window.collector)
        @window = nil
      end
    rescue StandardError => e
      Glass.error("profiler", e)
    end

    def after_fork
      # The parent's collector (if any) was stopped before the fork; if the
      # fork bypassed the hook, the inherited object is left alone and kept
      # referenced so its native side is never freed under live hooks.
      (@orphans ||= []) << @window.collector if @window
      @window = nil
      @pending = nil
    end

    def shutdown
      @lock.synchronize do
        stop_collector(@window.collector) if @window
        @window = nil
      end
    rescue StandardError
      nil
    end

    def running?
      !@window.nil?
    end

    # --- windows ------------------------------------------------------------

    private

    def available?
      return false if @unavailable
      return true if defined?(::Vernier::Collector)
      require "vernier"
      true
    rescue LoadError, StandardError => e
      @unavailable = true
      Glass.error("vernier", e)
      false
    end

    def foreign_profile?
      defined?(::Vernier) && ::Vernier.instance_variable_get(:@collector)
    end

    def open_window(now)
      return unless available?
      return if foreign_profile?
      if @pending
        req = @pending
        @pending = nil
        hz = req[:hz]
        seconds = req[:seconds]
        request_id = req[:id]
      else
        hz = @config.profile_hz
        seconds = @config.profile_window
        request_id = nil
      end
      collector = ::Vernier::Collector.new(:wall, interval: (1_000_000 / hz).clamp(1_000, 100_000))
      collector.start
      @window = Window.new(collector, Time.now.to_f, now, now + seconds, hz, request_id)
    rescue StandardError => e
      @window = nil
      Glass.error("profiler", e)
    end

    def close_window
      window = @window
      @window = nil
      result = stop_collector(window.collector)
      return nil unless result
      ended = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rec = Fold.new(@config).fold(result, @intervals.take, started_wall: window.started_wall,
                                                            dur: ended - window.started_mono, hz: window.hz)
      rec[:request] = window.request_id if rec && window.request_id
      rec
    rescue StandardError => e
      Glass.error("profiler", e)
      nil
    end

    def stop_collector(collector)
      collector.stop
    rescue StandardError => e
      Glass.error("profiler", e)
      nil
    end

    # A Vernier result → one `profile` record. Works on anything shaped
    # like Vernier's result (threads keyed by Thread#object_id, a stack
    # table with the index accessors), which is what the tests feed it.
    class Fold
      def initialize(config)
        @config = config
        @paths = Paths.new(config.app_root)
      end

      # intervals: [[thread_id, start_s, finish_s | nil, name], ...]
      def fold(result, intervals, started_wall:, dur:, hz:)
        st = result.stack_table
        interval_ns = interval_ns_for(result, hz)
        pauses = gc_pauses(result)
        by_thread = intervals.group_by(&:first)
        weights = Hash.new(0) # [vernier stack idx, name, state] => weight

        result.threads.each do |tid, th|
          samples = th[:samples] or next
          ivs = (by_thread[tid] || []).map { |(_, s, e, name)| [(s * 1e9).to_i, e ? (e * 1e9).to_i : nil, name.to_s] }
          ivs.sort_by!(&:first)
          attribute(samples, th[:weights], th[:timestamps], th[:sample_categories], ivs, interval_ns, pauses, weights)
        end
        return nil if weights.empty?
        build(st, weights, started_wall, dur, hz)
      end

      private

      # Walk one thread's run-length encoded samples. An entry with weight
      # w at time t stands for ticks t, t+step, … up to the next entry; the
      # ticks are split across the transaction intervals they fall in.
      # Ticks Vernier could not take because the thread was in GC show up
      # as a shortfall against the elapsed time and become `gc` samples.
      def attribute(samples, ws, ts, cats, ivs, interval_ns, pauses, out)
        n = samples.size
        cursor = 0
        n.times do |i|
          stack = samples[i]
          w = ws[i]
          t = ts[i]
          state = STATES[cats[i]] || "running"
          t_next = i + 1 < n ? ts[i + 1] : t + w * interval_ns
          span = t_next - t
          step = w > 1 ? [interval_ns, span / w].min : interval_ns
          step = 1 if step < 1
          # GC shortfall
          if pauses && i + 1 < n && (cats[i] || 0).zero?
            expected = (span.to_f / interval_ns).round
            missing = expected - w
            if missing.positive?
              overlap = gc_overlap(pauses, t, t_next)
              if overlap.positive?
                gc_w = [missing, (overlap.to_f / interval_ns).ceil].min
                out[[stack, name_at(ivs, t, cursor), "gc"]] += gc_w
              end
            end
          end
          # advance the interval cursor past intervals that ended before t
          cursor += 1 while cursor < ivs.size && ivs[cursor][1] && ivs[cursor][1] <= t
          if w == 1 || ivs.empty?
            name = ivs.empty? ? nil : name_at(ivs, t, cursor)
            out[[stack, name, state]] += w unless name.nil? && state == "idle"
            next
          end
          k = 0
          c = cursor
          while k < w
            tick = t + k * step
            c += 1 while c < ivs.size && ivs[c][1] && ivs[c][1] <= tick
            iv = c < ivs.size ? ivs[c] : nil
            if iv && iv[0] <= tick
              limit = iv[1] ? ((iv[1] - tick).to_f / step).ceil : w
              count = [w - k, [limit, 1].max].min
              out[[stack, iv[2], state]] += count
            else
              limit = iv ? ((iv[0] - tick).to_f / step).ceil : w
              count = [w - k, [limit, 1].max].min
              out[[stack, nil, state]] += count unless state == "idle"
            end
            k += count
          end
        end
      end

      def name_at(ivs, t, cursor)
        i = cursor
        while i < ivs.size
          s, e, name = ivs[i]
          return nil if s > t
          return name if e.nil? || t < e
          i += 1
        end
        nil
      end

      def interval_ns_for(result, hz)
        meta = result.respond_to?(:meta) ? result.meta : nil
        us = meta && meta[:interval]
        us && us.positive? ? us * 1_000 : (1_000_000_000 / hz)
      end

      # Sorted [start, end] GC pause intervals, or nil if the result has
      # no markers to read.
      # Vernier's marker type for a GC pause (its enum; the constant when
      # the gem is loaded, the same value for a synthetic result).
      GC_PAUSE = 7

      def gc_pauses(result)
        return nil unless result.respond_to?(:gc_markers)
        markers = result.gc_markers or return nil
        type = defined?(::Vernier::Marker::Type::GC_PAUSE) ? ::Vernier::Marker::Type::GC_PAUSE : GC_PAUSE
        pauses = markers.filter_map { |m| [m[2], m[3]] if m[0] == type && m[3] && m[2] && m[3] > m[2] }
        pauses.sort_by!(&:first)
        pauses.empty? ? nil : pauses
      rescue StandardError
        nil
      end

      def gc_overlap(pauses, from, to)
        total = 0
        # binary search the first pause that ends after `from`
        lo = 0
        hi = pauses.size
        while lo < hi
          mid = (lo + hi) / 2
          if pauses[mid][1] <= from then lo = mid + 1 else hi = mid end
        end
        while lo < pauses.size && pauses[lo][0] < to
          s, e = pauses[lo]
          total += [e, to].min - [s, from].max
          lo += 1
        end
        total
      end

      # Resolve stacks to root-first function chains, dedupe by content,
      # cap the record at MAX_STACKS heaviest stacks.
      def build(st, weights, started_wall, dur, hz)
        per_stack = Hash.new(0)
        weights.each { |(stack, _, _), w| per_stack[stack] += w }
        kept = per_stack.keys
        truncated = nil
        if kept.size > MAX_STACKS
          kept = kept.sort_by { |s| -per_stack[s] }.first(MAX_STACKS)
          truncated = {}
          kept.each { |s| truncated[s] = true }
        end

        funcs = []
        func_index = {}   # content => local index
        vfunc_local = {}  # vernier func idx => local index
        chains = {}       # vernier stack idx => local func chain (root first)
        stacks = []
        stack_index = {}  # chain => local stack index
        samples = Hash.new(0)

        resolve = lambda do |idx|
          chains[idx] ||= begin
            frame = st.stack_frame_idx(idx)
            vf = st.frame_func_idx(frame)
            local = vfunc_local[vf] ||= begin
              content = func_content(st, vf)
              func_index[content] ||= (funcs << content; funcs.size - 1)
            end
            parent = st.stack_parent_idx(idx)
            parent.nil? ? [local] : resolve.call(parent) + [local]
          end
        end

        trunc_local = nil
        weights.each do |(stack, name, state), w|
          if truncated && !truncated[stack]
            trunc_local ||= (funcs << TRUNCATED.dup; funcs.size - 1)
            chain = [trunc_local]
          else
            chain = resolve.call(stack)
          end
          local_stack = stack_index[chain] ||= (stacks << chain; stacks.size - 1)
          samples[[local_stack, name, state]] += w
        end

        {
          t: "profile", ts: started_wall, dur: dur.round(3), hz: hz, mode: "wall",
          funcs: funcs, stacks: stacks,
          samples: samples.map { |(s, name, state), w| [s, name, state, w] }
        }
      end

      def func_content(st, vf)
        name = st.func_name(vf).to_s
        file, category = @paths.classify(st.func_filename(vf).to_s)
        line = st.func_first_lineno(vf).to_i
        [name, file, line, category]
      end
    end

    # Filenames as the record wants them: relative to the app root for app
    # code, relative to the gem root prefixed by the gem's name (no
    # version, so a gem upgrade is the same function), never absolute.
    class Paths
      # The last "gems/<name-version>/" on the path: an rbenv install has an
      # earlier "/gems/3.4.0/" segment that is not the gem.
      GEM_DIR = %r{\A.*/(?:gems|bundler/gems)/([^/]+)/(.+)\z}
      VERSION_SUFFIX = /-\d+(?:\.[\w]+)*(?:-[a-z0-9_]+)*\z|-[0-9a-f]{7,40}\z/

      def initialize(app_root)
        @root = app_root.to_s.chomp("/")
        @root_prefix = @root.empty? ? nil : @root + "/"
        @glass_root = File.expand_path("../..", __dir__) + "/"
        @ruby_dirs = %w[rubylibdir rubyarchdir sitelibdir sitearchdir vendorlibdir].filter_map do |k|
          d = RbConfig::CONFIG[k]
          d && !d.empty? ? d.chomp("/") + "/" : nil
        end.uniq
        @cache = {}
      end

      def classify(filename)
        @cache[filename] ||= compute(filename)
      end

      private

      def compute(filename)
        return ["<cfunc>", "native"] if filename.empty? || filename == "<cfunc>"
        return [filename, "ruby"] if filename.start_with?("<internal:")
        return ["(eval)", "app"] if filename.start_with?("(")
        return ["glass/" + filename.delete_prefix(@glass_root), "gem"] if filename.start_with?(@glass_root)
        @ruby_dirs.each do |dir|
          return [filename.delete_prefix(dir), "ruby"] if filename.start_with?(dir)
        end
        if (m = GEM_DIR.match(filename))
          return [m[1].sub(VERSION_SUFFIX, "") + "/" + m[2], "gem"]
        end
        if @root_prefix && filename.start_with?(@root_prefix)
          rel = filename.delete_prefix(@root_prefix)
          return [rel, rel.start_with?("vendor/") ? "gem" : "app"]
        end
        # Elsewhere on disk: keep the tail, never the absolute path.
        [filename.split("/").last(3).join("/"), "gem"]
      end
    end
  end
end
