# typed: strict
# frozen_string_literal: true

module Triage
  # A finding as a task for an agent: Markdown that stands on its own —
  # what is wrong, the numbers, the evidence as text, where to look with
  # Glass's MCP tools, and what "fixed" means. The console's "Copy for an
  # agent" and the `triage` MCP tool hand over this same text.
  module Brief
    extend T::Sig

    MAX_ROWS = 8

    sig { params(detail: Detail, window: Window).returns(String) }
    def self.render(detail, window:)
      finding = detail.finding
      lines = [
        "# #{finding.title}",
        "",
        "**#{finding.severity.serialize.capitalize}** · #{finding.subject.kind.serialize.tr('_', ' ')} · " \
        "#{window.from.utc.iso8601} → #{window.to.utc.iso8601} (compared with the #{duration(window.baseline_to - window.baseline_from)} before)",
        "",
        finding.summary,
        "",
        "## What this is",
        "",
        detail.description,
        "",
        "## Facts",
        "",
        *detail.facts.map { |fact| "- **#{fact.label}:** #{fact.value}" },
        "",
        "## Evidence",
        *detail.evidence.flat_map { |evidence| [ "" ] + section(evidence) },
        "",
        "## Dig further with Glass",
        "",
        "Glass's MCP server reads the same data. The rows behind this finding are `#{detail.source}` filtered by " \
        "`#{detail.filter}` — pass that to `query` (shape `list` for rows, `table` with `group_by` for a breakdown).",
        *trace_hint(detail),
        "",
        "## Suggested steps",
        "",
        *detail.steps.each_with_index.map { |step, index| "#{index + 1}. #{step}" }
      ]
      "#{lines.join("\n").gsub(/\n{3,}/, "\n\n").strip}\n"
    end

    sig { params(evidence: Evidence).returns(T::Array[String]) }
    def self.section(evidence)
      head = [ "### #{evidence.title}", "" ]
      head += [ "_#{evidence.note}_", "" ] if evidence.note
      type = evidence.type
      body =
        case type
        when Evidence::Type::Chart then chart(evidence)
        when Evidence::Type::Table then markdown_table(evidence)
        when Evidence::Type::Traces then evidence.rows.first(MAX_ROWS).map { |row| trace_line(row) }
        when Evidence::Type::Logs then evidence.rows.first(MAX_ROWS).map { |row| log_line(row) }
        when Evidence::Type::Functions then evidence.rows.first(MAX_ROWS).map { |row| function_line(row) }
        when Evidence::Type::Markers then evidence.rows.first(MAX_ROWS).map { |row| marker_line(row) }
        else T.absurd(type)
        end
      head + body
    end
    private_class_method :section

    sig { params(evidence: Evidence).returns(T::Array[String]) }
    def self.chart(evidence)
      query = evidence.query || {}
      [ "A timeseries of `#{Array(query['compute']).join(', ')}` over `#{query['source']}`" \
        "#{query['metric'] ? " (#{query['metric']})" : ''} filtered by `#{query['filter']}`, " \
        "from #{time(query['from'])} to #{time(query['to'])}." ]
    end
    private_class_method :chart

    sig { params(evidence: Evidence).returns(T::Array[String]) }
    def self.markdown_table(evidence)
      columns = evidence.columns
      rows = evidence.rows.first(MAX_ROWS).map do |row|
        "| #{columns.map { |column| cell(row[column.key], column.unit).gsub('|', '\\|') }.join(' | ')} |"
      end
      [ "| #{columns.map(&:label).join(' | ')} |", "|#{columns.map { ' --- |' }.join}" ] + rows
    end
    private_class_method :markdown_table

    sig { params(value: T.untyped, unit: T.nilable(String)).returns(String) }
    def self.cell(value, unit)
      return "—" if value.nil? || value == ""

      case unit
      when "ms" then Words.ms(value)
      when "ratio" then Words.percent(value)
      when "usd" then Words.usd(value)
      when "time" then time(value)
      when "sha" then value.to_s.first(12)
      else
        return Words.clip(value, 160) unless value.is_a?(Numeric)

        value.to_f == value.to_f.round ? Words.count(value) : value.to_f.round(3).to_s
      end
    end
    private_class_method :cell

    sig { params(row: T::Hash[String, T.untyped]).returns(String) }
    def self.trace_line(row)
      what = [ row["method"], row["path"] ].compact.join(" ").presence || row["name"]
      outcome = [ row["http_status"], row["error"] ].compact.join(" ")
      "- #{time(row['ts'])} — #{what}#{outcome.empty? ? '' : " → #{outcome}"} (#{Words.ms(row['duration'])}" \
        "#{row['db_count'] ? ", #{row['db_count']} queries" : ''}#{row['release'] ? ", release #{row['release'].to_s.first(12)}" : ''})" \
        "#{row['trace'] ? " · trace `#{row['trace']}`" : ''}"
    end
    private_class_method :trace_line

    sig { params(row: T::Hash[String, T.untyped]).returns(String) }
    def self.log_line(row)
      "- #{time(row['ts'])} [#{row['level']}] #{Words.clip(row['message'], 300)}#{row['trace'] ? " · trace `#{row['trace']}`" : ''}"
    end
    private_class_method :log_line

    sig { params(row: T::Hash[String, T.untyped]).returns(String) }
    def self.function_line(row)
      where = [ row["file"], row["line"].to_i.positive? ? row["line"] : nil ].compact.join(":")
      before = row["before_share"] ? ", #{Words.percent(row['before_share'])} before" : ", not in the top before"
      "- `#{row['name']}`#{where.empty? ? '' : " (#{where})"} — #{Words.percent(row['self_share'])} of sampled time on top of the stack#{before}"
    end
    private_class_method :function_line

    sig { params(row: T::Hash[String, T.untyped]).returns(String) }
    def self.marker_line(row)
      "- #{time(row['ts'])} #{row['kind']}: #{row['title']}#{row['release'] ? " (release #{row['release']})" : ''}"
    end
    private_class_method :marker_line

    sig { params(detail: Detail).returns(T::Array[String]) }
    def self.trace_hint(detail)
      trace = detail.evidence.flat_map(&:rows).filter_map { |row| row["trace"] }.first
      trace ? [ "", "Read one example whole with `get_trace` (`#{trace}`): its spans, logs and model calls." ] : []
    end
    private_class_method :trace_hint

    sig { params(value: T.untyped).returns(String) }
    def self.time(value) = value.nil? ? "—" : Time.at(value.to_f).utc.iso8601

    sig { params(seconds: Float).returns(String) }
    def self.duration(seconds)
      count, unit = seconds >= 1.day ? [ seconds / 1.day, "day" ] : [ seconds / 1.hour, "hour" ]
      count.round(1) == 1 ? unit : "#{Words.trim(count, 1)} #{unit.pluralize}"
    end
    private_class_method :duration
  end
end
