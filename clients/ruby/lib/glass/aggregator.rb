# frozen_string_literal: true

require_relative "sketch"

module Glass
  # In-process metric aggregation: every call lands in the series for its
  # (name, kind, sorted tags) inside the 10-second wall-clock window it
  # happened in. At flush, each closed window's series becomes one `metric`
  # record (docs/ingest-protocol.md). RED metrics from every transaction go
  # through here before any sampling decision, so throughput, error rate and
  # latency are exact whatever the trace sampler keeps.
  #
  # Thread safety: one mutex around one hash. The critical section is a
  # lookup and a few arithmetic updates; the key is built outside it.
  class Aggregator
    WINDOW = 10
    MAX_SERIES = 5_000
    MAX_TAGS = 20
    MAX_TAG_VALUE = 200
    MAX_SET_MEMBERS = 10_000
    NAME_FORMAT = /\A[a-zA-Z][a-zA-Z0-9_.:\-]{0,119}\z/
    KINDS = { counter: "counter", gauge: "gauge", dist: "dist", set: "set" }.freeze

    Series = Struct.new(:name, :kind, :unit, :tags, :n, :sum, :min, :max, :last, :sketch, :members)

    attr_reader :dropped

    def initialize(max_series: MAX_SERIES)
      @max_series = max_series
      @mutex = Mutex.new
      @windows = {} # window start (Integer seconds) => { key => Series }
      @dropped = 0
    end

    def counter(name, by, tags, now = nil, unit: nil)
      add(:counter, name, by, tags, unit, now)
    end

    def gauge(name, value, tags, now = nil)
      add(:gauge, name, value, tags, nil, now)
    end

    def dist(name, value, tags, unit = nil, now = nil)
      add(:dist, name, value, tags, unit, now)
    end

    def set(name, member, tags, now = nil)
      add(:set, name, member, tags, nil, now)
    end

    # Records for every window that has closed by `now` (all windows when
    # `force`, for the final flush at exit). Closed windows are discarded.
    def drain(now = Time.now.to_i, force: false)
      taken = @mutex.synchronize do
        keys = force ? @windows.keys : @windows.keys.select { |start| start + WINDOW <= now }
        keys.map { |k| [k, @windows.delete(k)] }
      end
      taken.flat_map { |start, series| series.values.map { |s| record(start, s) } }
    end

    # Drop count since the last call (the transport folds it into the
    # cumulative `dropped.metric` it reports).
    def take_dropped
      @mutex.synchronize do
        n = @dropped
        @dropped = 0
        n
      end
    end

    def reset!
      @mutex.synchronize do
        @windows.clear
        @dropped = 0
      end
    end

    private

    def add(kind, name, value, tags, unit, now)
      if kind == :set
        member = value.to_s
      else
        return unless value.is_a?(Numeric)
        value = value.to_f
        return unless value.finite?
      end
      tags = normalize_tags(tags)
      key = series_key(kind, name, tags)
      window = (now || Process.clock_gettime(Process::CLOCK_REALTIME, :second)) / WINDOW * WINDOW
      @mutex.synchronize do
        series = (@windows[window] ||= {})
        s = series[key]
        unless s
          if series.size >= @max_series || !NAME_FORMAT.match?(name.to_s)
            @dropped += 1
            return
          end
          s = series[key] = new_series(kind, name, unit, tags)
        end
        update(s, kind, value, member)
      end
      nil
    end

    def update(s, kind, value, member)
      case kind
      when :counter
        s.n += 1
        s.sum += value
      when :gauge
        s.n += 1
        s.sum += value
        s.min = value if s.min.nil? || value < s.min
        s.max = value if s.max.nil? || value > s.max
        s.last = value
      when :dist
        s.n += 1
        s.sum += value
        s.min = value if s.min.nil? || value < s.min
        s.max = value if s.max.nil? || value > s.max
        s.last = value
        s.sketch.add(value)
      when :set
        s.members[member] = true if s.members.size < MAX_SET_MEMBERS || s.members.key?(member)
      end
    end

    def new_series(kind, name, unit, tags)
      s = Series.new(name.to_s, kind, unit&.to_s, tags, 0, 0.0)
      s.sketch = Sketch.new if kind == :dist
      s.members = {} if kind == :set
      s
    end

    # Tags become string => string, sorted by key, capped in number and
    # length. Symbols and numbers are fine as values; nil values drop the
    # tag rather than the call.
    def normalize_tags(tags)
      return EMPTY_TAGS if tags.nil? || tags.empty?
      pairs = []
      tags.each do |k, v|
        next if v.nil?
        v = v.to_s
        pairs << [k.to_s, v.size > MAX_TAG_VALUE ? v[0, MAX_TAG_VALUE] : v]
      end
      pairs.sort_by!(&:first)
      pairs = pairs.first(MAX_TAGS) if pairs.size > MAX_TAGS
      pairs.to_h
    end

    EMPTY_TAGS = {}.freeze
    private_constant :EMPTY_TAGS

    def series_key(kind, name, tags)
      key = +"#{kind}\0#{name}"
      tags.each { |k, v| key << "\0" << k << "=" << v }
      key
    end

    def record(window, s)
      rec = { t: "metric", ts: window, name: s.name, kind: KINDS[s.kind] }
      rec[:unit] = s.unit if s.unit && !s.unit.empty?
      rec[:tags] = s.tags unless s.tags.empty?
      case s.kind
      when :counter
        rec[:n] = s.n
        rec[:sum] = s.sum
      when :gauge
        rec[:n] = s.n
        rec[:sum] = s.sum
        rec[:min] = s.min
        rec[:max] = s.max
        rec[:last] = s.last
      when :dist
        rec[:n] = s.n
        rec[:sum] = s.sum
        rec[:min] = s.min
        rec[:max] = s.max
        rec[:last] = s.last
        rec[:sk] = s.sketch.to_pairs
      when :set
        rec[:n] = s.members.size
      end
      rec
    end
  end
end
