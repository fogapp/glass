import { describe, expect, it } from "vitest";
import { computeSuggestions, fieldsInScope, functionNeedsField, kindsIn, railFields } from "@/lib/workFields";
import type { QueryCatalog, QueryField } from "@/types";

const field = (name: string, facet: QueryField["facet"], measure = false): QueryField => ({ name, label: name, type: "text", measure, unit: null, facet });
const catalog = {
  sources: [
    { name: "transactions", label: "", fields: [field("name", null), field("duration", null, true), field("http_status", "http"), field("db", "rails", true), field("queue", "queue"), field("cost", "ai", true), field("ttft", "experience", true), field("ext", "outbound", true)] },
    { name: "logs", label: "", fields: [field("level", null)] },
  ],
  kinds: [
    { name: "request", label: "Requests", noun: "Endpoint", facets: ["http", "rails", "outbound"], phases: [] },
    { name: "run", label: "Agent runs", noun: "Agent", facets: ["queue", "outbound", "ai", "experience"], phases: [] },
  ],
  functions: { events: [], metrics: [] },
  apps: [],
  metrics: [],
} as QueryCatalog;

describe("fields in scope", () => {
  it("reads the kinds a filter names", () => {
    expect(kindsIn("app:aio kind:run status:error")).toEqual(["run"]);
    expect(kindsIn("kind:request,job")).toEqual(["request", "job"]);
    expect(kindsIn("-kind:run notkind:x")).toEqual([]);
  });

  it("offers the spine and the facets of the kinds in scope", () => {
    const names = (filter: string) => fieldsInScope(catalog, "transactions", filter).map((entry) => entry.name);
    expect(names("kind:run")).toEqual(["name", "duration", "queue", "cost", "ttft", "ext"]);
    expect(names("kind:request")).toEqual(["name", "duration", "http_status", "db", "ext"]);
    expect(names("kind:request,run")).toHaveLength(8);
  });

  it("offers everything with no kind named, for a kind it does not know, and on any other source", () => {
    expect(fieldsInScope(catalog, "transactions", "app:hook")).toHaveLength(8);
    expect(fieldsInScope(catalog, "transactions", "kind:deploy")).toHaveLength(8);
    expect(fieldsInScope(catalog, "logs", "kind:run").map((entry) => entry.name)).toEqual(["level"]);
    expect(fieldsInScope(undefined, "transactions", "kind:run")).toEqual([]);
  });

  it("builds the facet rail from the kinds in scope", () => {
    expect(railFields(catalog, "kind:run")).toEqual(["app", "kind", "name", "status", "release", "process", "error", "queue", "channel", "trigger", "stop", "model"]);
    expect(railFields(catalog, "")).toContain("http_status");
    expect(railFields(catalog, "kind:request")).not.toContain("channel");
  });
});

describe("functionNeedsField", () => {
  it("follows Query::Compute and Query::Metrics", () => {
    for (const fn of ["count", "rate", "errors", "error_rate", "apdex"]) expect(functionNeedsField(fn, "transactions")).toBeNull();
    for (const fn of ["sum", "avg", "min", "max", "p50", "p95", "p99"]) expect(functionNeedsField(fn, "transactions")).toBe("measure");
    expect(functionNeedsField("uniq", "page_events")).toBe("dimension");
    expect(functionNeedsField("ratio", "model_calls")).toBe("pair");
    for (const fn of ["sum", "avg", "last", "p95", "count", "rate"]) expect(functionNeedsField(fn, "metrics")).toBeNull();
  });

  it("suggests each function with the fields it can take", () => {
    const fields = [field("name", null), field("duration", null, true)];
    expect(computeSuggestions(["count", "p95", "uniq", "ratio"], "transactions", fields)).toEqual(["count", "p95(duration)", "uniq(name)"]);
    expect(computeSuggestions(["last", "p95"], "metrics", fields)).toEqual(["last", "p95"]);
  });
});
