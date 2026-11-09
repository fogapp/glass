/**
 * The one place query keys are defined. Each resource exposes `all` as the
 * invalidation prefix, with factories nested under it, so a single
 * invalidateQueries({ queryKey: keys.x.all }) refreshes lists AND details
 * (react-query matches by prefix). Inline key literals are lint-banned.
 */
import type { QuerySpec } from "@/types";

export const keys = {
  session: {
    all: ["session"] as const,
    setup: () => [...keys.session.all, "setup"] as const,
  },
  users: {
    all: ["users"] as const,
    list: () => [...keys.users.all, "list"] as const,
  },
  passkeys: {
    all: ["passkeys"] as const,
    list: () => [...keys.passkeys.all, "list"] as const,
  },
  apiTokens: {
    all: ["apiTokens"] as const,
    list: () => [...keys.apiTokens.all, "list"] as const,
  },
  about: {
    all: ["about"] as const,
    detail: () => [...keys.about.all, "detail"] as const,
  },
  jobs: {
    all: ["jobs"] as const,
    list: () => [...keys.jobs.all, "list"] as const,
    /** A mutation key: the runs being started, so each job's button knows its own. */
    run: () => [...keys.jobs.all, "run"] as const,
  },
  activity: {
    all: ["activity"] as const,
    list: (severity: string, page: number) => [...keys.activity.all, "list", { severity, page }] as const,
  },
  apps: {
    all: ["apps"] as const,
    list: () => [...keys.apps.all, "list"] as const,
    detail: (slug: string) => [...keys.apps.all, "detail", slug] as const,
    keys: (appId: string) => [...keys.apps.all, "keys", appId] as const,
  },
  settings: {
    all: ["settings"] as const,
    detail: () => [...keys.settings.all, "detail"] as const,
    storage: () => [...keys.settings.all, "storage"] as const,
  },
  status: {
    all: ["status"] as const,
    line: () => [...keys.status.all, "line"] as const,
  },
  fleet: {
    all: ["fleet"] as const,
    list: () => [...keys.fleet.all, "list"] as const,
  },
  triage: {
    all: ["triage"] as const,
    list: (from: number, to: number, app: string) => [...keys.triage.all, "list", { from, to, app }] as const,
    detail: (id: string, from: number, to: number) => [...keys.triage.all, "detail", id, { from, to }] as const,
  },
  /** Telemetry reads: the spec is the key, so identical questions share an answer. */
  query: {
    all: ["query"] as const,
    run: (spec: QuerySpec) => [...keys.query.all, "run", spec] as const,
    batch: (specs: QuerySpec[]) => [...keys.query.all, "batch", specs] as const,
    catalog: () => [...keys.query.all, "catalog"] as const,
    values: (source: string, key: string, from: number, to: number, filter: string, q: string, metric: string) =>
      [...keys.query.all, "values", { source, key, from, to, filter, q, metric }] as const,
  },
  visitors: {
    all: ["visitors"] as const,
    journeys: (from: number, to: number, filter: string) => [...keys.visitors.all, "journeys", { from, to, filter }] as const,
  },
  markers: {
    all: ["markers"] as const,
    range: (from: number, to: number, app: string) => [...keys.markers.all, "range", { from, to, app }] as const,
  },
  traces: {
    all: ["traces"] as const,
    detail: (id: string) => [...keys.traces.all, "detail", id] as const,
  },
  dashboards: {
    all: ["dashboards"] as const,
    list: () => [...keys.dashboards.all, "list"] as const,
    detail: (id: string) => [...keys.dashboards.all, "detail", id] as const,
  },
  monitors: {
    all: ["monitors"] as const,
    list: () => [...keys.monitors.all, "list"] as const,
    detail: (id: string) => [...keys.monitors.all, "detail", id] as const,
    incidents: () => [...keys.monitors.all, "incidents"] as const,
  },
  profiles: {
    all: ["profiles"] as const,
    flamegraph: (body: unknown) => [...keys.profiles.all, "flamegraph", body] as const,
  },
} as const;
