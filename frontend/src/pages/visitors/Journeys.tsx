import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { Panel, QueryBody } from "@/components/charts/Panel";
import { roundRange } from "@/lib/glassQuery";
import { keys } from "@/lib/queryKeys";
import { useScope } from "@/lib/scope";
import { formatCount, formatPercent } from "@/lib/format";
import { Meter } from "@/components/ui/Meter";

/** The paths visitors take from page to page. */
export function JourneysTab() {
  const scope = useScope();
  const { from, to } = roundRange(scope.range);
  const edges = useQuery({
    queryKey: keys.visitors.journeys(from, to, scope.filter),
    queryFn: () => api.get<{ edges: { from: string; to: string; count: number }[] }>(`/visitors/journeys?from=${from}&to=${to}&filter=${encodeURIComponent(scope.filter)}`),
    refetchInterval: scope.live ? 30_000 : false,
  });
  // Grouped, totalled and sorted once per answer, on copies: the cached answer is never reordered.
  const byFrom = useMemo(() => {
    const groups = new Map<string, { to: string; count: number }[]>();
    for (const edge of edges.data?.edges ?? []) (groups.get(edge.from) ?? groups.set(edge.from, []).get(edge.from)!).push(edge);
    return Array.from(groups.entries(), ([from, targets]) => ({
      from,
      total: targets.reduce((sum, edge) => sum + edge.count, 0),
      targets: [...targets].sort((a, b) => b.count - a.count).slice(0, 6),
    })).sort((a, b) => b.total - a.total);
  }, [edges.data]);
  return (
    <Panel title="Where people go next" subtitle="pageview → pageview transitions within a visit, most travelled first">
      <QueryBody query={edges} height={200} isEmpty={(data) => data.edges.length === 0}>
        {() => (
          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
            {byFrom.map(({ from, total, targets }) => (
              <div key={from} className="rounded-[var(--radius-card)] border border-border p-3">
                <p className="mb-2 font-mono text-[13px] text-foreground">
                  from <span className="text-primary">{from}</span> <span className="text-muted">({formatCount(total)})</span>
                </p>
                <ul className="space-y-1">
                  {targets.map((edge) => (
                    <li key={edge.to} className="flex items-center gap-2 text-xs">
                      <span className="text-muted">→</span>
                      <span className="min-w-0 flex-1 truncate font-mono text-foreground">{edge.to}</span>
                      <Meter value={edge.count / total} />
                      <span className="tabular w-10 text-right font-mono text-muted">{formatPercent(edge.count / total, 0)}</span>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        )}
      </QueryBody>
    </Panel>
  );
}
