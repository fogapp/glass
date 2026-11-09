/**
 * An agent harness's page: built, like every app's,
 * from what it reported and nothing else. A harness reports runs — one per
 * thing asked of it — and every model call; these are the views of those.
 * Latency here is always *active* time: the run's duration less the time it
 * spent waiting on a person.
 */

export { HarnessOverview } from "@/pages/app/harness/Overview";
export { InteractionsTab } from "@/pages/app/harness/Interactions";
export { ModelsTab } from "@/pages/app/harness/Models";
export { ToolsTab } from "@/pages/app/harness/Tools";
export { SessionSheet } from "@/pages/app/harness/SessionSheet";
