import { useMemo, useState } from "react";
import { MousePointerClick, Smartphone } from "lucide-react";
import { QueryBody } from "@/components/charts/Panel";
import { Sheet } from "@/components/ui/Sheet";
import { Badge } from "@/components/ui/Badge";
import { useGlassBatch } from "@/lib/glassQuery";
import { Failures } from "@/components/ui/Failures";
import { useScopedNavigate } from "@/lib/scopeHref";
import { term } from "@/lib/explore";
import { formatDateTime, formatMs } from "@/lib/format";
import { useNow } from "@/hooks/useNow";
import { cn } from "@/lib/cn";
import { listRows } from "@/lib/listRows";
import type { ListResult, TransactionRow } from "@/types";

/** One visit opened as a timeline beside the list it was picked from. */

interface PageEventRow {
  ts: number;
  kind: string;
  path: string | null;
  route: string | null;
  title: string | null;
  name: string | null;
  selector: string | null;
  href: string | null;
  lcp: number | null;
  inp: number | null;
  cls: number | null;
  rage: boolean;
}

/** One visit as a timeline: pages, clicks, vitals, errors and the API requests they caused. */
export function VisitSheet({ visit, onClose }: { visit: string; onClose: () => void }) {
  // A visit is not bounded by the scope bar's range: it is looked for where its rows are kept.
  const now = useNow();
  const navigate = useScopedNavigate();
  const kept = { from: now - 30 * 86_400, to: now + 60 };
  const { batch, answer, failures } = useGlassBatch({
    events: { source: "page_events", shape: "list", ...kept, filter: term("visit", visit), limit: 300 },
    requests: { source: "transactions", shape: "list", ...kept, filter: term("visit", visit), limit: 300 },
  });
  const [showRequests, setShowRequests] = useState(true);
  const events = answer<ListResult>("events");
  const requests = answer<ListResult>("requests");
  const timeline = useMemo(() => {
    const pages = listRows<PageEventRow>(events).map((row) => ({ ...row, source: "page" as const }));
    const txns = showRequests ? listRows<TransactionRow>(requests).map((row) => ({ ...row, source: "request" as const })) : [];
    return [...pages, ...txns].sort((a, b) => a.ts - b.ts);
  }, [events, requests, showRequests]);
  const first = timeline[0]?.ts;
  return (
    <Sheet open onClose={onClose} title="Visit" description={visit} size="lg">
      <label className="mb-2 flex items-center gap-2 text-xs text-muted">
        <input type="checkbox" checked={showRequests} onChange={(event) => setShowRequests(event.target.checked)} /> show the API requests this visit made
      </label>
      <Failures messages={failures} />
      <QueryBody query={batch} height={200} isEmpty={() => (events?.rows.length ?? 0) === 0}>
        {() => (
          <ol className="relative ml-2 border-l border-border pl-4">
            {timeline.map((item, index) => (
              <li key={index} className="relative py-1.5 text-xs">
                <span className={cn("absolute -left-[21px] top-2.5 h-2 w-2 rounded-full", dotClass(item))} aria-hidden />
                <span className="tabular mr-2 font-mono text-muted">+{first === undefined ? 0 : (item.ts - first).toFixed(1)}s</span>
                {item.source === "page" ? <PageLine event={item} /> : <RequestLine row={item} onOpen={() => navigate(`/traces/${item.trace}`)} />}
              </li>
            ))}
          </ol>
        )}
      </QueryBody>
      <p className="mt-2 text-[11px] text-muted">First event {first ? formatDateTime(first) : "—"}.</p>
    </Sheet>
  );
}

function dotClass(item: { source: "page"; kind: string } | { source: "request"; status: string }): string {
  if (item.source === "request") return item.status === "error" ? "bg-negative" : "bg-muted";
  switch (item.kind) {
    case "pageview":
      return "bg-primary";
    case "error":
      return "bg-negative";
    case "vital":
      return "bg-surface-raised";
    default:
      return "bg-warning";
  }
}

function PageLine({ event }: { event: PageEventRow }) {
  switch (event.kind) {
    case "pageview":
      return (
        <span className="text-foreground">
          viewed <span className="font-mono">{event.path}</span> {event.title ? <span className="text-muted">— {event.title}</span> : null}
        </span>
      );
    case "click":
    case "submit":
      return (
        <span className="text-foreground">
          <MousePointerClick className="mr-1 inline h-3 w-3 text-warning" aria-hidden />
          {event.kind === "submit" ? "submitted" : "clicked"} <span className="font-medium">{event.name ?? "(unnamed)"}</span>
          {event.selector ? <span className="ml-1 font-mono text-muted">{event.selector}</span> : null}
          {event.rage ? <Badge tone="warning" className="ml-1">rage</Badge> : null}
        </span>
      );
    case "vital":
      return (
        <span className="text-muted">
          <Smartphone className="mr-1 inline h-3 w-3" aria-hidden />
          page felt: LCP {formatMs(event.lcp)} · INP {formatMs(event.inp)} · CLS {event.cls?.toFixed(3) ?? "—"}
        </span>
      );
    case "error":
      return (
        <span className="text-negative">
          error <span className="font-mono">{event.name}</span>
        </span>
      );
    default:
      return (
        <span className="text-foreground">
          event <span className="font-medium">{event.name}</span>
        </span>
      );
  }
}

function RequestLine({ row, onOpen }: { row: TransactionRow; onOpen: () => void }) {
  return (
    <button type="button" onClick={onOpen} className="text-left text-muted hover:text-foreground">
      <span className={cn("font-mono", row.status === "error" && "text-negative")}>
        {row.method} {row.path}
      </span>{" "}
      → {row.http_status} in {formatMs(row.duration)}
      {row.kept ? <span className="ml-1 text-primary">trace</span> : null}
    </button>
  );
}
