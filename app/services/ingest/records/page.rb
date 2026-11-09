# typed: strict
# frozen_string_literal: true

module Ingest
  module Records
    # A `page` record → a `page_events` row.
    module Page
      extend T::Sig

      MAX_PROPS = 32

      sig { params(record: Record, context: Context).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def self.build(record, context)
        kind = record["kind"]
        visit = Coerce.str(record["visit"], max: 64)
        return nil unless Telemetry::PageEvent::KINDS.include?(kind) && visit

        ua = record["ua"].is_a?(Hash) ? record["ua"] : {}
        vitals = record["vitals"].is_a?(Hash) ? record["vitals"] : {}
        el = record["el"].is_a?(Hash) ? record["el"] : {}
        device = ua["device"]
        origin = record["origin"]
        props = Coerce.attrs(record["props"]).first(MAX_PROPS).to_h
        {
          **context.stamp(record), kind: kind, visit_id: visit,
          visitor_id: Coerce.str(record["visitor"], max: 64), user_ref: Coerce.str(record["user"], max: 120),
          path: Coerce.str(record["path"], max: 2_000), route: Coerce.str(record["route"], max: 500),
          title: Coerce.str(record["title"], max: 200), referrer: referrer_host(record["ref"]),
          name: Coerce.str(record["name"], max: 200), selector: Coerce.str(el["sel"], max: 300),
          href: Coerce.str(el["href"], max: 500),
          browser: Coerce.str(ua["browser"], max: 40), os: Coerce.str(ua["os"], max: 40),
          device: Coerce.one_of(device, Telemetry::PageEvent::DEVICES, nil), screen: Coerce.str(ua["screen"], max: 20),
          lang: Coerce.str(record["lang"], max: 20), origin: Coerce.one_of(origin, Telemetry::ORIGINS, nil),
          trace_id: Coerce.trace_id(record["trace"]),
          rage: props.delete("rage") == true,
          lcp: Coerce.ms(vitals["lcp"]), inp: Coerce.ms(vitals["inp"]), cls: Coerce.float(vitals["cls"]),
          ttfb: Coerce.ms(vitals["ttfb"]), fcp: Coerce.ms(vitals["fcp"]),
          props: props
        }
      end

      # Only the host of a referrer: enough to say "from the portal", nothing to
      # say what page of it.
      sig { params(value: T.untyped).returns(T.nilable(String)) }
      def self.referrer_host(value)
        return nil unless value.is_a?(String) && value.present?

        host = URI.parse(value).host
        host.presence&.first(200)
      rescue URI::Error
        value.first(200)
      end
      private_class_method :referrer_host
    end
  end
end
