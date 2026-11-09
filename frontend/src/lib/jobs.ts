import type { BadgeTone } from "@/components/ui/Badge";
import type { JobRunStatus } from "@/types";

export const JOB_RUN_STATUS_LABELS: Record<JobRunStatus, string> = {
  queued: "Queued",
  running: "Running",
  succeeded: "Succeeded",
  failed: "Failed",
};

export const JOB_RUN_STATUS_TONES: Record<JobRunStatus, BadgeTone> = {
  queued: "info",
  running: "info",
  succeeded: "success",
  failed: "danger",
};
