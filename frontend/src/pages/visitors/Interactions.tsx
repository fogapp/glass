import { Panel, QueryBody } from "@/components/charts/Panel";
import { BatchTimeseries } from "@/components/charts/BatchTimeseries";
import { BarList } from "@/components/charts/BarList";
import { useGlassBatch } from "@/lib/glassQuery";
import { Failures } from "@/components/ui/Failures";
import { useScope, withScope } from "@/lib/scope";
import { useExploreHref, term } from "@/lib/explore";
import { formatCount, num } from "@/lib/format";
import { tableToBars } from "@/lib/bars";
import type { TableResult } from "@/types";

/** What visitors did on a page: clicks, custom events, rage clicks, browser errors. */
export function InteractionsTab() {
  const explore = useExploreHref();
  const scope = useScope();
  const glass = useGlassBatch(
    {
      clicks: { source: "page_events", shape: "table", filter: withScope(scope, "kind:click,submit"), compute: ["count", "uniq(visit)"], group_by: ["name", "route"], limit: 40 },
      custom: { source: "page_events", shape: "table", filter: withScope(scope, "kind:custom"), compute: ["count", "uniq(visit)"], group_by: ["name"], limit: 20 },
      rage: { source: "page_events", shape: "table", filter: withScope(scope, "rage:true"), compute: ["count"], group_by: ["name", "route"], limit: 10 },
      errors: { source: "page_events", shape: "table", filter: withScope(scope, "kind:error"), compute: ["count", "uniq(visit)"], group_by: ["name", "route"], limit: 10 },
      trend: { source: "page_events", shape: "timeseries", filter: withScope(scope, "kind:click,submit,custom"), compute: ["count"], group_by: ["name"], limit: 6 },
    },
    { live: scope.live },
  );
  const { batch, answer, failures } = glass;
  const rows = (which: "clicks" | "custom" | "rage" | "errors") =>
    tableToBars(answer<TableResult>(which), {
      key: (row) => `${row.name}:${row.route ?? ""}`,
      measure: "count",
      format: formatCount,
      label: (row) => `${row.name ?? "(unnamed)"}${row.route ? `  ·  ${row.route}` : ""}`,
      secondary: (row) => (row["uniq(visit)"] !== undefined ? `${formatCount(num(row["uniq(visit)"]))} visits` : undefined),
      href: (row) => explore({ source: "page_events", shape: "list", filter: [term("name", row.name as string), row.route ? term("route", row.route as string) : ""].join(" ").trim() }),
    });
  return (
    <div className="space-y-3">
      <Failures messages={failures} />
      <Panel title="Interactions over time" subtitle="clicks, submits and events, by name">
        <BatchTimeseries batch={glass} answer="trend" stacked />
      </Panel>
      <div className="grid gap-3 lg:grid-cols-2">
        <Panel title="What gets clicked" subtitle="autocaptured buttons and links, by accessible name and page">
          <QueryBody query={batch} height={200}>{() => <BarList rows={rows("clicks")} emptyLabel="No interactions captured" />}</QueryBody>
        </Panel>
        <div className="space-y-3">
          <Panel title="Custom events" subtitle="glass.track(…)">
            <QueryBody query={batch} height={80}>{() => <BarList rows={rows("custom")} emptyLabel="No custom events" />}</QueryBody>
          </Panel>
          <Panel title="Rage clicks" subtitle="the same thing clicked three times in a second">
            <QueryBody query={batch} height={80}>{() => <BarList rows={rows("rage")} emptyLabel="None — nothing is being hammered" />}</QueryBody>
          </Panel>
          <Panel title="Browser errors">
            <QueryBody query={batch} height={80}>{() => <BarList rows={rows("errors")} emptyLabel="No errors in the browser" />}</QueryBody>
          </Panel>
        </div>
      </div>
    </div>
  );
}
