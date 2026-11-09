# typed: strict
# frozen_string_literal: true

module Triage
  module Detectors
    # A page that feels slow to the people using it: its 75th-percentile
    # web vitals past Google's "poor" line.
    class Vitals < Detector
      MIN_COUNT = 10
      VITALS = "kind:vital"
      # The "poor" thresholds (web.dev/vitals), at p75 as they are judged.
      POOR = T.let({ "lcp" => 4_000.0, "inp" => 500.0, "cls" => 0.25 }.freeze, T::Hash[String, Float])
      # "Needs improvement" — reported, and scored lower.
      SLOW = T.let({ "lcp" => 2_500.0, "inp" => 200.0, "cls" => 0.1 }.freeze, T::Hash[String, Float])
      NAMES = T.let({ "lcp" => "Largest Contentful Paint", "inp" => "Interaction to Next Paint", "cls" => "Cumulative Layout Shift" }.freeze,
        T::Hash[String, String])

      sig { override.returns(Kind) }
      def self.kind = Kind::Vitals

      sig { override.returns(T::Array[Finding]) }
      def findings
        rows = scan.table(source: "page_events", group_by: %w[app route], compute: [ "count", "p75(lcp)", "p75(inp)", "p75(cls)" ],
          filter: scan.filter(narrow || VITALS), limit: 200)
        rows.filter_map do |row|
          next if row["count"].to_f < MIN_COUNT || row["route"].nil?

          worst = SLOW.keys.filter_map do |vital|
            value = row["p75(#{vital})"]&.to_f
            value && value >= SLOW.fetch(vital) ? [ vital, value, value / POOR.fetch(vital) ] : nil
          end.max_by(&:last)
          next if worst.nil?

          vital, value, ratio = worst
          subject = Subject.new(kind: self.class.kind, app: row["app"], work: nil, name: row["route"].to_s)
          finding(subject, score: 15 + 35 * scale(ratio, 1.5) + 10 * scale(row["count"], 500.0),
            title: "#{row['app']} · #{row['route']} has a #{ratio >= 1 ? 'poor' : 'slow'} #{vital.upcase}",
            summary: "p75 #{NAMES.fetch(vital)} is #{vital == 'cls' ? value.round(2) : Words.ms(value)} over " \
                     "#{Words.count(row['count'])} page loads (poor is past #{vital == 'cls' ? POOR.fetch(vital) : Words.ms(POOR.fetch(vital))}).",
            figures: { "count" => row["count"], "vital" => vital, "value" => value, "lcp" => row["p75(lcp)"], "inp" => row["p75(inp)"],
                       "cls" => row["p75(cls)"] })
        end
      end

      sig { override.params(finding: Finding).returns(Detail) }
      def detail(finding)
        subject = finding.subject
        filter = subject_filter(subject)
        vital = finding.figures["vital"].to_s
        by = ->(field) { scan.table(source: "page_events", group_by: [ field ], compute: [ "count", "p75(#{vital})" ], filter: filter, limit: 6) }
        unit = vital == "cls" ? nil : "ms"
        worst = scan.list(source: "page_events", filter: filter, limit: 10, order: "-#{vital}")
        evidence = [
          chart("p75 #{vital.upcase}", scan.chart(source: "page_events", filter: filter, compute: [ "p75(#{vital})" ])),
          table("By device", [ column("device", "Device"), column("count", "Loads"), column("p75(#{vital})", "p75", unit) ], by.call("device")),
          table("By browser", [ column("browser", "Browser"), column("count", "Loads"), column("p75(#{vital})", "p75", unit) ], by.call("browser")),
          table("Worst page loads", [ column("ts", "When", "time"), column("path", "Path"), column("device", "Device"),
            column(vital, vital.upcase, unit), column("trace", "Request", "trace") ], worst)
        ]
        Detail.build(finding: finding,
          description: "#{advice(vital)} The breakdowns say whether it is everyone or one kind of device; " \
                       "the worst loads link to the server request that served them where one was traced.",
          facts: [ fact("App", subject.app), fact("Route", subject.name), fact("Vital", NAMES[vital]),
                   fact("p75 LCP", finding.figures["lcp"] && Words.ms(finding.figures["lcp"])),
                   fact("p75 INP", finding.figures["inp"] && Words.ms(finding.figures["inp"])),
                   fact("p75 CLS", finding.figures["cls"]&.to_f&.round(3)) ].compact,
          evidence: evidence,
          steps: [
            "Find the component or template that renders #{subject.name}.",
            "#{advice(vital)}",
            "Done when p75 #{vital.upcase} is under #{vital == 'cls' ? SLOW.fetch(vital) : Words.ms(SLOW.fetch(vital))}."
          ],
          source: "page_events", filter: filter)
      end

      private

      sig { override.params(subject: Subject).returns(String) }
      def subject_terms(subject) = [ VITALS, Query::Filter.quote("route", subject.name) ].join(" ")

      sig { params(vital: String).returns(String) }
      def advice(vital)
        case vital
        when "lcp" then "A slow LCP is the main content arriving late: a slow server response (check TTFB), a large image " \
                        "or font, or content rendered only after a client-side fetch."
        when "inp" then "A slow INP is the page not answering a tap or keypress: long JavaScript work on the main thread " \
                        "during an interaction — a large re-render, synchronous parsing, a heavy handler."
        else "A high CLS is content moving after it appeared: images and embeds without dimensions, content inserted " \
             "above what is already there, late web fonts."
        end
      end
    end
  end
end
