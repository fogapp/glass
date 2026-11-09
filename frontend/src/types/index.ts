/**
 * The shapes the API answers with, mirroring app/serializers. `api.get<T>`
 * trusts these — when a serializer changes, this file changes in the same
 * commit. Closed vocabularies mirror the backend enums as `as const` lists.
 */

// ---- platform ---------------------------------------------------------

export interface User {
  id: string;
  email: string;
  name: string;
  role: UserRole;
  household_id: string;
}

export interface WebauthnCredential {
  id: string;
  nickname: string | null;
  created_at: string;
  last_used_at: string | null;
}

export interface SessionResponse {
  token: string;
  user: User;
}

/** SetupController#show — whether this instance still needs its first-run
 *  wizard, and how the console signs people in. */
export interface SetupStatus {
  setup_required: boolean;
  /** Sign in with an OpenID provider (fog): offered when configured, and
   *  the only way in once Glass has proven it runs on fog. */
  signin: { enabled: boolean; fog_only: boolean };
}

export interface ApiToken {
  id: string;
  name: string;
  /** The first characters of the token — all that is ever shown again. */
  prefix: string;
  scope: ApiTokenScope;
  expires_at: string | null;
  expired: boolean;
  last_used_at: string | null;
  created_at: string;
}

/** The create response: the token itself, shown this once. */
export interface ApiTokenCreated extends ApiToken {
  token: string;
}

export interface TestResult {
  ok: boolean;
  message: string;
}

export interface MachineInfo {
  hostname: string;
  os: string;
  kernel: string;
  arch: string;
  cpus: number;
  memory_total_bytes: number | null;
  containerized: boolean;
  pid: number;
  user: string | null;
}

export interface About {
  git_sha: string;
  git_sha_short: string;
  environment: string;
  ruby_version: string;
  rails_version: string;
  postgres_version: string | null;
  time_zone: string;
  booted_at: string;
  machine: MachineInfo;
  storage: {
    state_dir: string;
    total_bytes: number | null;
    free_bytes: number | null;
  };
}

export interface JobRun {
  id: string;
  job_key: string;
  status: JobRunStatus;
  trigger: JobRunTrigger;
  message: string | null;
  error: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

export interface ManagedJob {
  key: string;
  label: string;
  description: string;
  runs: JobRun[];
}

export interface ActivityEntry {
  id: string;
  source: string;
  event: string;
  severity: ActivitySeverity;
  summary: string;
  subject_type: string | null;
  subject_id: string | null;
  subject: { type: string; id: string | null; label: string | null; path: string | null } | null;
  payload: Record<string, unknown>;
  duration_ms: number | null;
  trace_id: string | null;
  created_at: string;
}

// ---- apps and keys ----------------------------------------------------

export { ACTIVITY_SEVERITIES, API_TOKEN_SCOPES, HEADER_ICONS, HEADER_SIZES, IDENTITY_MODES, LABEL_PARTS, JOB_RUN_STATUSES, JOB_RUN_TRIGGERS, LOG_LEVELS, MARKER_KINDS, MCP_TOOLS, METRIC_KINDS, MONITOR_KINDS, MONITOR_STATES, PAGE_EVENT_KINDS, PROFILE_STATES, QUERY_SHAPES, QUERY_SOURCES, SPAN_KINDS, TRIAGE_EVIDENCE_TYPES, TRIAGE_KINDS, TRIAGE_SEVERITIES, USER_ROLES, WORK_FACETS } from "./generated";
export type { ActivitySeverity, ApiTokenScope, HeaderIcon, HeaderSize, IdentityMode, LabelPart, JobRunStatus, JobRunTrigger, LogLevel, MarkerKind, McpTool, MetricKind, MonitorKind, MonitorState, ProfileState, QueryShape, QuerySource, SpanKind, TriageDismissalMode, TriageEvidenceType, TriageKind, TriageSeverity, UserRole, WorkFacet } from "./generated";
import type { ActivitySeverity, ApiTokenScope, HeaderIcon, HeaderSize, IdentityMode, LabelPart, JobRunStatus, JobRunTrigger, LogLevel, MarkerKind, MetricKind, MonitorKind, MonitorState, QueryShape, QuerySource, SpanKind, TriageDismissalMode, TriageEvidenceType, TriageKind, TriageSeverity, UserRole, WorkFacet } from "./generated";

/** What an app's agents are told on every flush (AgentSettings). */
export interface AgentSettings {
  trace_sample_rate: number;
  profiling: boolean;
  profile_hz: number;
  log_level: LogLevel;
  browser: boolean;
}

export interface App {
  id: string;
  slug: string;
  name: string;
  /** 1..8 — the categorical chart slot the app keeps for life. */
  color_slot: number;
  fog_name: string | null;
  identity_mode: IdentityMode;
  /** A link into the app's own console for what Glass is never sent: `https://assistant.example.net/traces/{run}`. */
  link_template: string | null;
  /** What fog last said about the app, when fog is connected and knows it. */
  fog: { rev?: number; healthy?: boolean | null; state?: string; hosts?: string[] } | null;
  agent_settings: AgentSettings;
  first_seen_at: number | null;
  last_seen_at: number | null;
  reporting: boolean;
  live_processes: number;
  release: string | null;
  /** The kinds of unit of work it has reported lately: `request`, `job`, `run`. */
  kinds: string[];
  created_at: number;
}

/** The create response carries the first key, shown this once. */
export interface AppCreated extends App {
  ingest_key: string;
}

export interface IngestKey {
  id: string;
  name: string;
  prefix: string;
  last_used_at: string | null;
  revoked_at: string | null;
  revoked: boolean;
  created_at: string;
}

export interface IngestKeyCreated extends IngestKey {
  token: string;
}

// ---- settings ---------------------------------------------------------

export interface RetentionRow {
  table: string;
  label: string;
  days: number;
  default_days: number;
  max_days: number;
  overridden: boolean;
}

export interface Settings {
  ntfy_url: string | null;
  ntfy_topic: string;
  ntfy_token_set: boolean;
  last_tested_at: string | null;
  last_test_ok: boolean | null;
  last_test_message: string | null;
  disk_budget_mb: number;
  retention: RetentionRow[];
  fog: {
    url: string | null;
    token_set: boolean;
    sync_enabled: boolean;
    /** Fog apps removed from Glass: the sync leaves them alone until followed again. */
    ignored_apps: string[];
    last_synced_at: string | null;
    last_error: string | null;
    last_tested_at: string | null;
    last_test_ok: boolean | null;
    last_test_message: string | null;
  };
}

export interface StorageReport {
  used_bytes: number;
  budget_bytes: number;
  /** Series, stacks and functions: counted in used_bytes, pruned rather than shed. */
  dictionary_bytes: number;
  tables: { table: string; label: string; bytes: number; retention_days: number; days: { day: string; bytes: number }[] }[];
}

// ---- telemetry --------------------------------------------------------

export interface Status {
  now: number;
  apps: { total: number; reporting: number };
  processes: { live: number; total: number };
  last_seen_at: number | null;
  /** Requests and jobs a second over the last minute. */
  throughput: number;
  storage: { used_bytes: number; budget_bytes: number };
  release: string;
}

export interface AgentProcess {
  id: number;
  app: string | null;
  kind: string;
  host: string;
  pid: number;
  release: string | null;
  runtime: Record<string, string>;
  started_at: number | null;
  first_seen_at: number;
  last_seen_at: number;
  live: boolean;
  batches: number;
  records: number;
  dropped: Record<string, number>;
}

export interface Marker {
  ts: number;
  app: string | null;
  kind: MarkerKind;
  title: string;
  release: string | null;
  source: string;
  attrs: Record<string, unknown>;
}

// ---- the query engine -------------------------------------------------

/** What is posted to /api/v1/query (Query::Request). */
export interface QuerySpec {
  source: QuerySource;
  shape: QueryShape;
  from: number;
  to: number;
  filter?: string;
  compute?: string[];
  group_by?: string[];
  step?: number;
  limit?: number;
  order?: string;
  metric?: string;
  field?: string;
  before?: number;
}

export interface QueryColumn {
  key: string;
  label: string;
  kind: "dimension" | "measure";
  unit?: string | null;
}

export type CellValue = string | number | boolean | null;

export interface TableResult {
  shape: "table";
  from: number;
  to: number;
  columns: QueryColumn[];
  rows: Record<string, CellValue>[];
  metric?: string;
  kind?: string;
}

export interface Series {
  key: string;
  group: Record<string, CellValue>;
  unit: string | null;
  values: (number | null)[];
}

export interface TimeseriesResult {
  shape: "timeseries";
  from: number;
  to: number;
  step: number;
  times: number[];
  series: Series[];
  metric?: string;
  kind?: string;
}

export interface ListResult {
  shape: "list";
  from: number;
  to: number;
  rows: Record<string, unknown>[];
  next_before: number | null;
}

export interface HeatmapResult {
  shape: "heatmap";
  from: number;
  to: number;
  step: number;
  times: number[];
  field: string;
  unit: string | null;
  edges: number[];
  /** [time index, bucket index, count] */
  cells: [number, number, number][];
}

export interface HistogramResult {
  shape: "histogram";
  from: number;
  to: number;
  field: string;
  unit: string | null;
  edges: number[];
  counts: number[];
}

/** What every answer may say beside its own shape. */
interface AnswerScope {
  /** The apps the filter confined it to (`Query::Context#apps_in`); absent when it reads every app. */
  apps?: string[];
}

export type QueryResult = (TableResult | TimeseriesResult | ListResult | HeatmapResult | HistogramResult) & AnswerScope;

/** One answer of a batched query: a result, or the reason there is none. */
export type QueryAnswer = QueryResult | { errors: string[] };

export interface QueryField {
  name: string;
  label: string;
  type: "text" | "integer" | "number" | "boolean" | "trace" | "app";
  measure: boolean;
  unit: string | null;
  /** The facet of a unit of work the field belongs to; null for the spine every kind has. */
  facet: WorkFacet | null;
}

/** A kind of unit of work (Telemetry::Work): which facets it carries, and the phases that add up to its duration. */
export interface WorkKind {
  name: string;
  label: string;
  /** What `name` holds for this kind: Endpoint, Job, Agent. */
  noun: string;
  facets: WorkFacet[];
  phases: string[];
}

export interface MetricInfo {
  name: string;
  kind: MetricKind;
  unit: string | null;
  series: number;
  apps: string[];
  tags: string[];
}

export interface QueryCatalog {
  sources: { name: string; label: string; fields: QueryField[] }[];
  kinds: WorkKind[];
  functions: { events: string[]; metrics: string[] };
  apps: string[];
  metrics: MetricInfo[];
}

export interface FacetValue {
  value: string | number | boolean | null;
  count: number | null;
}

// ---- transactions as listed ------------------------------------------

/** `request`, `job`, `run` — or a kind the server has no declaration for yet. */
export type WorkKindName = "request" | "job" | "run" | (string & {});

/** What only a run carries (the `ai` and `experience` facets). */
export interface RunFields {
  agent: string | null;
  session: string | null;
  trigger: string | null;
  channel: string | null;
  stop: string | null;
  model: string | null;
  rounds: number;
  calls: number;
  tools: number;
  tool_errors: number;
  tokens_in: number;
  tokens_out: number;
  cache_read: number;
  cache_write: number;
  cost: number;
  prep: number;
  model_ms: number;
  tool_ms: number;
  wait: number;
  deliver: number;
  lag: number | null;
  ttft: number | null;
  stall: number | null;
}

export interface TransactionRow extends RunFields {
  ts: number;
  app: string | null;
  kind: WorkKindName;
  name: string;
  status: "ok" | "error";
  http_status: number | null;
  method: string | null;
  path: string | null;
  duration: number;
  db: number;
  db_count: number;
  view: number;
  ext: number;
  gc: number;
  release: string | null;
  process: string;
  host: string | null;
  user: string | null;
  visit: string | null;
  origin: string | null;
  error: string | null;
  trace: string;
  span: string;
  kept: boolean;
  n_plus_one: boolean;
  queue: string | null;
  queue_ms: number | null;
  attrs: Record<string, unknown>;
}

export interface LogRow {
  ts: number;
  app: string | null;
  level: "debug" | "info" | "warn" | "error" | "fatal";
  message: string;
  source: string;
  process: string;
  host: string | null;
  release: string | null;
  trace: string | null;
  span: string | null;
  attrs: Record<string, unknown>;
}

// ---- traces -----------------------------------------------------------

export interface TraceTransaction extends Partial<RunFields> {
  ts: number;
  app: string | null;
  kind: WorkKindName;
  name: string;
  process: string;
  host: string | null;
  release: string | null;
  span: string;
  parent: string | null;
  duration: number;
  status: "ok" | "error";
  error: string | null;
  method: string | null;
  route: string | null;
  path: string | null;
  http_status: number | null;
  format: string | null;
  queue: string | null;
  queue_ms: number | null;
  attempt: number | null;
  db: number;
  db_count: number;
  view: number;
  ext: number;
  ext_count: number;
  cache_hits: number;
  cache_misses: number;
  gc: number;
  allocations: number | null;
  n_plus_one: boolean;
  user: string | null;
  visit: string | null;
  origin: string | null;
  kept: boolean;
  attrs: Record<string, unknown>;
}

export interface TraceSpan {
  ts: number;
  app: string | null;
  span: string;
  parent: string | null;
  kind: SpanKind;
  name: string;
  resource: string | null;
  duration: number;
  status: "ok" | "error";
  attrs: Record<string, unknown>;
}

export interface Trace {
  trace: string;
  started_at: number;
  duration_ms: number;
  truncated: boolean;
  transactions: TraceTransaction[];
  spans: TraceSpan[];
  /** The model calls made under the trace; `span` names the `model` span each one was. */
  model_calls: TraceModelCall[];
}

/** One call to a model (TraceSerializer.model_call_json). Never any text. */
export interface TraceModelCall {
  ts: number;
  app: string | null;
  span: string | null;
  provider: string;
  model: string;
  served: string | null;
  purpose: string;
  origin: string;
  agent: string | null;
  round: number | null;
  status: "ok" | "error";
  error: string | null;
  stop: string | null;
  route: string | null;
  retry_of: string | null;
  fallback_from: string | null;
  duration: number;
  ttft: number | null;
  first_text: number | null;
  server_queue: number | null;
  load: number | null;
  prompt: number | null;
  decode: number | null;
  tokens_in: number;
  cache_read: number;
  cache_write: number;
  tokens_out: number;
  reasoning: number;
  estimated: boolean;
  cost: number;
  cost_source: string | null;
  tools: number;
  tools_valid: number | null;
}

// ---- profiles ---------------------------------------------------------

export interface FlamegraphFunction {
  name: string;
  file: string;
  line: number;
  category: "app" | "gem" | "ruby" | "node" | "native" | "root" | "other";
}

/** Profiles::Flamegraph — nodes are preorder, heaviest child first. */
export interface Flamegraph {
  total_ms: number;
  baseline_total_ms: number | null;
  samples: number[];
  functions: FlamegraphFunction[];
  /** [function index, parent node index, self ms, total ms, (baseline self, baseline total)] */
  nodes: number[][];
  diff: boolean;
}

// ---- saved questions --------------------------------------------------

/** Its place on the dashboard's twelve-column grid (`lib/dashboardLayout`), in columns and rows. */
interface WidgetPlace {
  id: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface QueryWidget extends WidgetPlace {
  kind: "query";
  /** Its header and subheader: text of its own, or — when blank — the parts named (`lib/widgetLabels`). */
  title: string;
  subtitle: string;
  title_parts: LabelPart[];
  subtitle_parts: LabelPart[];
  spec: Partial<Pick<QuerySpec, "source" | "shape" | "filter" | "compute" | "group_by" | "metric" | "field" | "limit">> & { source: QuerySource };
}

/** A line of text (and a quieter one under it) naming the stretch of dashboard below. */
export interface HeaderWidget extends WidgetPlace {
  kind: "header";
  title: string;
  subtitle: string;
  size: HeaderSize;
  icon: HeaderIcon | null;
}

export type Widget = QueryWidget | HeaderWidget;

export interface Dashboard {
  id: string;
  name: string;
  description: string | null;
  widgets: Widget[];
  position: number;
  updated_at: string;
}

export interface Incident {
  id: string;
  monitor_id: string;
  opened_at: string;
  closed_at: string | null;
  peak_value: number | null;
  app: string | null;
  notified_at: string | null;
  monitor?: string;
  condition?: string;
}

export interface Monitor {
  id: string;
  name: string;
  description: string | null;
  enabled: boolean;
  kind: MonitorKind;
  query: { source?: string; filter?: string; compute?: string; metric?: string };
  comparison: "gt" | "lt";
  threshold: number;
  window_seconds: number;
  for_seconds: number;
  deploy_grace_seconds: number;
  notify: boolean;
  state: MonitorState;
  state_since: string | null;
  last_value: number | null;
  last_evaluated_at: string | null;
  last_error: string | null;
  condition: string;
  app: string | null;
  open_incident?: Incident | null;
  incidents?: Incident[];
}

// ---- triage -------------------------------------------------------------

/** One thing worth fixing (TriageSerializer.finding_json). */
export interface TriageFinding {
  /** The subject, encoded: stable across reloads and ranges. */
  id: string;
  kind: TriageKind;
  severity: TriageSeverity;
  /** 0–100, comparable across kinds. */
  score: number;
  app: string | null;
  /** request / job / run, a model's provider — whatever narrows `name`. */
  work: string | null;
  name: string;
  title: string;
  summary: string;
  figures: Record<string, string | number | boolean | null>;
  /** Someone's answer to it (TriageSerializer.dismissal_json); on a listed finding, a dismissal it has outgrown. */
  dismissal: TriageDismissal | null;
}

/** A finding dismissed (out of the list until it is worse) or ignored (out for good). */
export interface TriageDismissal {
  mode: TriageDismissalMode;
  /** How bad it was when it was dismissed. */
  score: number;
  severity: TriageSeverity;
  at: number;
  by: string | null;
  /** Worse than it was: a higher severity, or a score of `returns_above` or more. */
  regressed: boolean;
  /** dismissed: the score that brings it back. null when ignored. */
  returns_above: number | null;
}

export interface TriageReport {
  from: number;
  to: number;
  /** The comparison window runs from here to `from`. */
  baseline_from: number;
  findings: TriageFinding[];
  /** What stands out but someone dismissed or ignored, worst first. */
  hidden: TriageFinding[];
}

export interface TriageColumn {
  key: string;
  label: string;
  /** formatUnit's units, plus "time" (Unix seconds), "trace" (a link) and "sha" (a release). */
  unit: string | null;
}

/** What a finding rests on; `type` says which of the other fields it uses. */
export interface TriageEvidence {
  type: TriageEvidenceType;
  title: string;
  note: string | null;
  /** chart: the question, asked through /query like any other chart. */
  query: QuerySpec | null;
  columns: TriageColumn[];
  rows: Record<string, unknown>[];
}

export interface TriageDetail extends TriageFinding {
  from: number;
  to: number;
  baseline_from: number;
  description: string;
  facts: { label: string; value: string }[];
  evidence: TriageEvidence[];
  steps: string[];
  /** The rows behind it: `filter` over `source`. */
  source: QuerySource;
  filter: string;
  /** The finding as a Markdown task for an agent. */
  brief: string;
}
