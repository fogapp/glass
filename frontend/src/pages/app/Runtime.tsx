import { useMemo } from "react";
import { Panel } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { Failures } from "@/components/ui/Failures";
import { useGlassBatch } from "@/lib/glassQuery";
import { useScope } from "@/lib/scope";
import { runtimeCharts } from "@/lib/runtimeCharts";
import { useCatalog } from "@/components/telemetry/QueryBar";
import type { App } from "@/types";

/** The process's vitals, from whatever the app's runtime reports. */
export function RuntimeTab({ app }: { app: App }) {
  const scope = useScope();
  const catalog = useCatalog();
  // Built from what the app reports: Ruby's vitals, Node's, and its own gauges.
  const charts = useMemo(() => runtimeCharts(catalog.data?.metrics, app.slug), [catalog.data, app.slug]);
  // Each chart's answer is named by its metric.
  const glass = useGlassBatch(
    Object.fromEntries(charts.map((chart) => [chart.metric, { source: "metrics", shape: "timeseries", filter: `app:${app.slug}`, metric: chart.metric, compute: [chart.compute], group_by: ["process"] } as const])),
    { live: scope.live },
  );
  return (
    <div className="space-y-4">
      <Failures messages={glass.failures} />
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {charts.map((chart) => (
          <Panel key={chart.metric} title={chart.title} subtitle={chart.title === chart.metric ? undefined : chart.metric}>
            <BatchTimeseries batch={glass} answer={chart.metric} markersFor={app.slug} height={120} fromZero />
          </Panel>
        ))}
      </div>
    </div>
  );
}
