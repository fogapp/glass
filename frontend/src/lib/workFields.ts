import type { QueryCatalog, QueryField, WorkFacet } from "@/types";

/**
 * Which fields mean something for what a filter is looking at. A row of
 * `transactions` is a spine every kind has plus the facets its kind carries
 * (Telemetry::Work), so a filter that names a kind — `kind:run` — narrows
 * the fields worth offering to the spine and that kind's facets: tokens and
 * phases for a run, not an HTTP status. With no kind named, or on any other
 * source, every field is in scope.
 */
export function kindsIn(filter: string): string[] {
  const kinds: string[] = [];
  for (const match of filter.matchAll(/(?:^|\s)kind:([\w.,-]+)/g)) kinds.push(...match[1]!.split(",").filter(Boolean));
  return kinds;
}

export function facetsInScope(catalog: QueryCatalog | undefined, source: string, filter: string): Set<WorkFacet> | null {
  if (source !== "transactions" || !catalog) return null;
  const named = kindsIn(filter);
  if (named.length === 0) return null;
  const facets = new Set<WorkFacet>();
  for (const name of named) {
    const kind = catalog.kinds.find((entry) => entry.name === name);
    // A kind the server has no declaration for may carry anything.
    if (!kind) return null;
    for (const facet of kind.facets) facets.add(facet);
  }
  return facets;
}

export function fieldsInScope(catalog: QueryCatalog | undefined, source: string, filter: string): QueryField[] {
  const fields = catalog?.sources.find((entry) => entry.name === source)?.fields ?? [];
  const facets = facetsInScope(catalog, source, filter);
  return facets ? fields.filter((field) => field.facet === null || facets.has(field.facet)) : fields;
}

/** The fields worth a place in the Explorer's facet rail, per facet: the ones people slice by. */
const RAIL: Record<WorkFacet | "spine", string[]> = {
  spine: ["app", "kind", "name", "status", "release", "process", "error"],
  http: ["http_status", "method", "origin"],
  queue: ["queue"],
  rails: [],
  outbound: [],
  ai: ["channel", "trigger", "stop", "model"],
  experience: [],
};

/** The facet rail for transactions: the spine, then what the kinds in scope add. */
export function railFields(catalog: QueryCatalog | undefined, filter: string): string[] {
  const facets = facetsInScope(catalog, "transactions", filter);
  const extra = facets ? [...facets].flatMap((facet) => RAIL[facet]) : RAIL.http;
  return [...RAIL.spine, ...extra];
}

/**
 * What a compute function takes inside its parentheses (Query::Compute,
 * Query::Metrics): nothing for a metric — the metric is the field — nor for
 * a count, a rate, errors, an error rate or apdex (whose optional argument is
 * a threshold, not a field); a dimension for `uniq`; two measures for
 * `ratio`; one measure for every other (sum, avg, min, max, p50…p99).
 */
export type FunctionField = "measure" | "dimension" | "pair" | null;

const BARE_EVENT_FUNCTIONS = new Set(["count", "rate", "errors", "error_rate", "apdex"]);

export function functionNeedsField(fn: string, source: string): FunctionField {
  if (source === "metrics" || BARE_EVENT_FUNCTIONS.has(fn)) return null;
  if (fn === "uniq") return "dimension";
  if (fn === "ratio") return "pair";
  return "measure";
}

/** Every compute worth suggesting: each function, with each field it can take (a ratio is left to be written). */
export function computeSuggestions(functions: string[], source: string, fields: QueryField[]): string[] {
  const measures = fields.filter((field) => field.measure).map((field) => field.name);
  const dimensions = fields.filter((field) => !field.measure).map((field) => field.name);
  return functions.flatMap((fn) => {
    switch (functionNeedsField(fn, source)) {
      case null:
        return [fn];
      case "measure":
        return measures.map((measure) => `${fn}(${measure})`);
      case "dimension":
        return dimensions.map((dimension) => `${fn}(${dimension})`);
      case "pair":
        return [];
    }
  });
}
