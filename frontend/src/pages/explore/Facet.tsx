import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { roundRange } from "@/lib/glassQuery";
import { keys } from "@/lib/queryKeys";
import { useScope } from "@/lib/scope";
import { formatCount } from "@/lib/format";
import type { FacetValue } from "@/types";

/** One field of the facet rail: its commonest values in scope, each a click away from the filter. */
export function Facet({ source, facet, filter, metric, onPick }: { source: string; facet: string; filter: string; metric: string; onPick: (value: string) => void }) {
  const scope = useScope();
  const { from, to } = roundRange(scope.range);
  const values = useQuery({
    queryKey: keys.query.values(source, facet, from, to, filter, "", metric),
    queryFn: () =>
      api.get<FacetValue[]>(
        `/query/values?source=${source}&key=${encodeURIComponent(facet)}&from=${from}&to=${to}&filter=${encodeURIComponent(filter)}${metric ? `&metric=${encodeURIComponent(metric)}` : ""}`,
      ),
    staleTime: 30_000,
    enabled: source !== "metrics" || metric !== "",
  });
  const rows = (values.data ?? []).slice(0, 6);
  if (values.data && rows.length === 0) return null;
  const max = Math.max(...rows.map((row) => row.count ?? 0), 1);
  return (
    <div className="mb-3">
      <p className="mb-0.5 font-mono text-[11px] text-muted">{facet}</p>
      <ul className="space-y-px">
        {rows.map((row) => (
          <li key={String(row.value)}>
            <button
              type="button"
              onClick={() => onPick(String(row.value ?? ""))}
              className="relative flex w-full items-center justify-between gap-2 rounded px-1 py-0.5 text-left text-xs hover:bg-surface-raised"
              title={`Filter ${facet}:${String(row.value)}`}
            >
              <span className="absolute inset-y-0 left-0 rounded bg-primary/10" style={{ width: `${((row.count ?? 0) / max) * 100}%` }} aria-hidden />
              <span className="relative truncate font-mono text-foreground">{row.value === null ? "(none)" : String(row.value)}</span>
              <span className="tabular relative shrink-0 text-muted">{row.count === null ? "" : formatCount(row.count, 0)}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
