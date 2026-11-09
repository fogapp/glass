# typed: strict
# frozen_string_literal: true

# What an agent reads (McpController). The same facts the console's
# serializers carry, in the shape a model reads rather than the shape a
# chart draws: instants are ISO 8601 UTC instead of Unix floats, numbers
# keep four significant figures instead of fifteen, and blank fields are
# left out — every byte here is a token someone pays for.
module McpSerializer
  extend T::Sig

  SIGNIFICANT = 4
  MAX_TEXT = 2_000

  # ---- values --------------------------------------------------------------

  sig { params(value: T.untyped, precision: Integer).returns(T.nilable(String)) }
  def self.time(value, precision: 0)
    return nil if value.nil?

    # Rounded, not truncated: a float's microseconds are approximate, and a
    # paging cursor that lands a microsecond early skips a row.
    instant = value.is_a?(Numeric) ? Time.at(value.to_f) : value
    instant.utc.round(precision).iso8601(precision)
  end

  sig { params(value: T.untyped).returns(T.untyped) }
  def self.number(value)
    return value unless value.is_a?(Float)
    return nil unless value.finite?
    return value if value.zero?

    value.round([ SIGNIFICANT - 1 - Math.log10(value.abs).floor, 0 ].max)
  end

  # Every float in a nested answer, rounded.
  sig { params(value: T.untyped).returns(T.untyped) }
  def self.numbers(value)
    case value
    when Hash then value.transform_values { |item| numbers(item) }
    when Array then value.map { |item| numbers(item) }
    else number(value)
    end
  end

  # A row without its nils, empty strings and empty collections.
  sig { params(row: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
  def self.compact(row)
    row.reject { |_, value| value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?) }
  end

  # ---- query answers -------------------------------------------------------

  # A Query::Runner answer of any shape.
  sig { params(result: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def self.query_json(result)
    out = result.dup
    out[:from] = time(result[:from])
    out[:to] = time(result[:to])
    out[:times] = result[:times].map { |at| time(at) } if result.key?(:times)
    out[:step_seconds] = out.delete(:step) if out.key?(:step)
    if result[:shape] == "list"
      out[:rows] = result[:rows].map { |row| list_row(row) }
      out[:next_before] = time(result[:next_before], precision: 6)
    end
    out[:buckets] = histogram_buckets(out.delete(:edges), out.delete(:counts)) if result[:shape] == "histogram"
    numbers(out).compact
  end

  # One row of a `list`: a request, a span, a log line, a visit.
  sig { params(row: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def self.list_row(row)
    out = compact(row)
    out["ts"] = time(row["ts"], precision: 3)
    %w[message error].each do |key|
      text = out[key]
      out[key] = text.truncate(MAX_TEXT) if text.is_a?(String)
    end
    out
  end

  # A histogram's populated buckets, each with the bounds it counts between.
  sig { params(edges: T.untyped, counts: T.untyped).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.histogram_buckets(edges, counts)
    Array(counts).each_with_index.filter_map do |count, index|
      next unless count.to_f.positive?

      { from: edges[index], to: edges[index + 1], count: count }
    end
  end

  # ---- records -------------------------------------------------------------

  sig { params(app: App, health: T.nilable(AppHealth::Summary)).returns(T::Hash[Symbol, T.untyped]) }
  def self.app_json(app, health:)
    json = AppSerializer.app_json(app, health: health)
    {
      slug: json[:slug], name: json[:name], reporting: json[:reporting], live_processes: json[:live_processes],
      release: json[:release], first_seen_at: time(json[:first_seen_at]), last_seen_at: time(json[:last_seen_at]),
      fog: json[:fog].presence, identity_mode: json[:identity_mode], agent_settings: json[:agent_settings]
    }.compact
  end

  sig { params(process: Telemetry::AgentProcess, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
  def self.process_json(process, context)
    json = ProcessSerializer.process_json(process, context)
    %i[started_at first_seen_at last_seen_at].each { |key| json[key] = time(json[key]) }
    json.except(:id).compact
  end

  sig { params(marker: Telemetry::Marker, context: Query::Context).returns(T::Hash[Symbol, T.untyped]) }
  def self.marker_json(marker, context)
    json = MarkerSerializer.marker_json(marker, context)
    compact(json.merge(ts: time(json[:ts])))
  end

  sig { params(monitor: MonitorRule).returns(T::Hash[Symbol, T.untyped]) }
  def self.monitor_json(monitor)
    json = MonitorSerializer.monitor_json(monitor)
    open = json[:open_incident]
    json.slice(:id, :name, :description, :enabled, :kind, :condition, :app, :state, :last_error).merge(
      query: compact(monitor.query), state_since: time(json[:state_since]), last_value: number(json[:last_value]),
      last_evaluated_at: time(json[:last_evaluated_at]), open_incident: open && incident_times(open)
    ).compact
  end

  sig { params(incident: Incident).returns(T::Hash[Symbol, T.untyped]) }
  def self.incident_json(incident)
    rule = T.must(incident.monitor)
    json = incident_times(MonitorSerializer.incident_json(incident))
    {
      id: json[:id], monitor: rule.name, condition: rule.condition_text, app: json[:app], open: incident.open?,
      opened_at: json[:opened_at], closed_at: json[:closed_at], peak_value: json[:peak_value],
      query: compact(rule.query), notified_at: json[:notified_at]
    }.compact
  end

  # An incident as the console has it, its instants and its peak as an
  # agent reads them, blanks left out.
  sig { params(json: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def self.incident_times(json)
    compact(json.merge(opened_at: time(json[:opened_at]), closed_at: time(json[:closed_at]),
      notified_at: time(json[:notified_at]), peak_value: number(json[:peak_value])))
  end
  private_class_method :incident_times

  # A trace as a story: each request, job or run, then the spans under
  # them and the model calls those made, every start given as an offset
  # from the trace's own start. `note` says
  # what was left out, when something was.
  sig do
    params(found: Traces::Lookup::Found, context: Query::Context, logs: T::Array[T::Hash[String, T.untyped]],
      note: T.nilable(String)).returns(T::Hash[Symbol, T.untyped])
  end
  def self.trace_json(found, context, logs:, note: nil)
    json = TraceSerializer.trace_json(found, context)
    started = json[:started_at].to_f
    offset = ->(row) { compact(row.except(:ts).merge(offset_ms: (row[:ts].to_f - started) * 1000.0)) }
    numbers(
      trace: json[:trace], started_at: time(started, precision: 3), duration_ms: json[:duration_ms],
      note: note,
      transactions: json[:transactions].map(&offset), spans: json[:spans].map(&offset),
      model_calls: json[:model_calls].map(&offset).presence, logs: logs
    ).compact
  end
end
