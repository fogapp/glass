# frozen_string_literal: true

require "time"

module Glass
  # Runtime vitals, sampled every 10 s from the agent thread: GC, heap, RSS,
  # threads, YJIT, Puma's pool, Active Record's pools, Solid Queue's depth.
  # What belongs to this process carries its kind as the `process` tag, as
  # the Node agent's do, so a worker's memory is never averaged with the
  # web's; Solid Queue's depth is the database's, the same from every
  # process, and carries none.
  # Cheap by construction — GC.stat fills a reused hash, RSS is one small
  # file read on Linux (a `ps` at most once a minute elsewhere), and the
  # Solid Queue query runs at most every 30 s and only from a web or
  # worker process.
  class Runtime
    SOLID_QUEUE_EVERY = 30
    RSS_PS_EVERY = 60
    PAGE_SIZE = begin
      require "etc"
      Etc.sysconf(Etc::SC_PAGESIZE)
    rescue StandardError
      4_096
    end

    def initialize(config, aggregator)
      @config = config
      @agg = aggregator
      @stat = {}
      reset!
    end

    def reset!
      @gc_count = nil
      @gc_time = nil
      @sq_at = nil
      @sq_queues = {}
      @ps_at = nil
      @ps_rss = nil
    end

    def sample(process_kind = @config.process_kind)
      @tags = { process: process_kind.to_s }
      ruby
      puma
      active_record
      solid_queue if process_kind == "web" || process_kind == "worker"
    end

    private

    def ruby
      GC.stat(@stat)
      count = @stat[:count]
      @agg.counter("ruby.gc.count", count - @gc_count, @tags) if @gc_count
      @gc_count = count
      time = @stat[:time]
      if time
        @agg.counter("ruby.gc.time_ms", time - @gc_time, @tags) if @gc_time
        @gc_time = time
      end
      @agg.gauge("ruby.heap.live_slots", @stat[:heap_live_slots], @tags)
      @agg.gauge("ruby.heap.free_slots", @stat[:heap_free_slots], @tags)
      rss = rss_bytes
      @agg.gauge("ruby.memory.rss_bytes", rss, @tags) if rss
      @agg.gauge("ruby.threads", Thread.list.size, @tags)
      yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enabled?) && RubyVM::YJIT.enabled?
      @agg.gauge("ruby.yjit.enabled", yjit ? 1 : 0, @tags)
    rescue StandardError => e
      Glass.error("runtime.ruby", e)
    end

    def rss_bytes
      if File.readable?("/proc/self/statm")
        fields = File.read("/proc/self/statm").split(" ", 3)
        return fields[1].to_i * PAGE_SIZE
      end
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @ps_at.nil? || now - @ps_at >= RSS_PS_EVERY
        @ps_at = now
        out = `ps -o rss= -p #{Process.pid}`.strip
        @ps_rss = out.empty? ? nil : out.to_i * 1024
      end
      @ps_rss
    rescue StandardError
      nil
    end

    def puma
      return unless defined?(::Puma) && ::Puma.instance_variable_get(:@get_stats)
      stats = ::Puma.stats_hash
      return unless stats.is_a?(Hash)
      if stats.key?(:backlog)
        emit_puma(stats)
      elsif stats[:worker_status].is_a?(Array)
        # Cluster master: aggregate the workers' last reports. A forked
        # worker sees the same (stale, inherited) object and must not.
        workers = stats[:worker_status]
        return if workers.any? { |w| w[:pid] == Process.pid }
        sum = Hash.new(0)
        workers.each do |w|
          st = w[:last_status]
          next unless st.is_a?(Hash)
          st.each { |k, v| sum[k] += v if v.is_a?(Numeric) }
        end
        emit_puma(sum) unless sum.empty?
      end
    rescue StandardError => e
      Glass.error("runtime.puma", e)
    end

    def emit_puma(st)
      @agg.gauge("puma.backlog", st[:backlog], @tags) if st[:backlog]
      @agg.gauge("puma.running", st[:running], @tags) if st[:running]
      @agg.gauge("puma.pool_capacity", st[:pool_capacity], @tags) if st[:pool_capacity]
      busy = st[:busy_threads] || (st[:max_threads] && st[:pool_capacity] ? st[:max_threads] - st[:pool_capacity] : nil)
      @agg.gauge("puma.busy_threads", busy, @tags) if busy
    end

    def active_record
      return unless defined?(::ActiveRecord::Base)
      handler = ::ActiveRecord::Base.connection_handler
      pools = handler.respond_to?(:connection_pool_list) ? handler.connection_pool_list(:all) : []
      pools.each do |pool|
        st = pool.stat
        name = pool.respond_to?(:db_config) ? pool.db_config.name.to_s : "primary"
        tags = { pool: name, **@tags }
        @agg.gauge("active_record.pool.size", st[:size], tags)
        @agg.gauge("active_record.pool.busy", st[:busy], tags)
        @agg.gauge("active_record.pool.idle", st[:idle], tags)
        @agg.gauge("active_record.pool.waiting", st[:waiting], tags)
      end
    rescue StandardError => e
      Glass.error("runtime.active_record", e)
    end

    # Ready, scheduled and failed jobs, and the age of the oldest ready
    # one, by queue — one statement, one connection checkout, fully
    # rescued. A queue that empties still reports 0 (its last gauge would
    # otherwise stand forever).
    def solid_queue
      return unless defined?(::SolidQueue::ReadyExecution) && defined?(::SolidQueue::Record)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @sq_at && now - @sq_at < SOLID_QUEUE_EVERY
      @sq_at = now
      pool = ::SolidQueue::Record.connection_pool
      return unless pool && ::ActiveRecord::Base.connected?
      ready = ::SolidQueue::ReadyExecution.quoted_table_name
      scheduled = ::SolidQueue::ScheduledExecution.quoted_table_name
      failed = ::SolidQueue::FailedExecution.quoted_table_name
      sql = <<~SQL.gsub(/\s+/, " ").strip
        SELECT 'ready' AS k, queue_name, COUNT(*), MIN(created_at) FROM #{ready} GROUP BY queue_name
        UNION ALL SELECT 'scheduled', queue_name, COUNT(*), NULL FROM #{scheduled} GROUP BY queue_name
        UNION ALL SELECT 'failed', NULL, COUNT(*), NULL FROM #{failed}
      SQL
      rows = pool.with_connection { |c| c.select_rows(sql, "Glass Solid Queue") }
      seen = {}
      wall = Time.now.to_f
      rows.each do |kind, queue, count, oldest|
        queue = queue.to_s
        case kind
        when "ready"
          seen[queue] = true
          @agg.gauge("solid_queue.ready", count.to_i, { queue: queue })
          age = oldest_age(oldest, wall)
          @agg.gauge("solid_queue.oldest_ready_age_s", age, { queue: queue }) if age
        when "scheduled"
          @agg.gauge("solid_queue.scheduled", count.to_i, { queue: queue })
        when "failed"
          @agg.gauge("solid_queue.failed", count.to_i, {})
        end
      end
      @sq_queues.each_key do |queue|
        next if seen[queue]
        @agg.gauge("solid_queue.ready", 0, { queue: queue })
        @agg.gauge("solid_queue.oldest_ready_age_s", 0, { queue: queue })
      end
      @sq_queues = seen
    rescue StandardError => e
      Glass.error("runtime.solid_queue", e)
    end

    def oldest_age(value, wall)
      t =
        case value
        when Time then value.to_f
        when String then Time.parse(value.end_with?("UTC", "Z", "+00") ? value : value + " UTC").to_f
        else value.respond_to?(:to_time) ? value.to_time.to_f : nil
        end
      t ? [wall - t, 0.0].max.round(3) : nil
    rescue StandardError
      nil
    end
  end
end
