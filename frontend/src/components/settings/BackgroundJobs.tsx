import { useState } from "react";
import { useMutation, useMutationState, useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { JOB_RUN_STATUS_LABELS, JOB_RUN_STATUS_TONES } from "@/lib/jobs";
import { relativeTime } from "@/lib/time";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import type { ManagedJob } from "@/types";

/** Partition upkeep, rollups, pruning: each job's recent runs, and a button to run one now. */
export function BackgroundJobs() {
  const jobs = useQuery({ queryKey: keys.jobs.list(), queryFn: () => api.get<ManagedJob[]>("/background_jobs"), refetchInterval: 15_000 });
  const run = useMutation({
    mutationKey: keys.jobs.run(),
    mutationFn: (key: string) => api.post(`/background_jobs/${key}/run`),
    meta: { invalidates: [keys.jobs.all] },
  });
  // Only the jobs being started wait on their request; the others stay runnable.
  const starting = useMutationState({ filters: { mutationKey: keys.jobs.run(), status: "pending" }, select: (mutation) => mutation.state.variables as string });
  return (
    <section className="space-y-2">
      <SectionHeader title="Background jobs" description="Partition upkeep, rollups, pruning. Trigger a run and see recent history." />
      <QueryState query={jobs} errorMessage="Could not load jobs.">
        {(managed) => (
          <div className="divide-y divide-border">
            {managed.map((job) => (
              <JobRow key={job.key} job={job} onRun={() => run.mutate(job.key)} running={starting.includes(job.key)} />
            ))}
          </div>
        )}
      </QueryState>
    </section>
  );
}

function JobRow({ job, onRun, running }: { job: ManagedJob; onRun: () => void; running: boolean }) {
  const [open, setOpen] = useState(false);
  const latest = job.runs[0];
  const active = job.runs.some((run) => run.status === "queued" || run.status === "running");
  return (
    <div className="py-3">
      <div className="flex flex-wrap items-center gap-3">
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium text-foreground">{job.label}</p>
          <p className="text-xs text-muted">{job.description}</p>
        </div>
        {latest ? (
          <span className="flex items-center gap-2 text-xs text-muted">
            <Badge tone={JOB_RUN_STATUS_TONES[latest.status]}>{JOB_RUN_STATUS_LABELS[latest.status]}</Badge>
            {relativeTime(latest.finished_at ?? latest.started_at ?? latest.created_at)}
          </span>
        ) : (
          <span className="text-xs text-muted">never run</span>
        )}
        <Button size="sm" variant="secondary" onClick={onRun} disabled={running || active}>
          {active ? "Running…" : "Run now"}
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setOpen((value) => !value)} aria-expanded={open}>
          {open ? "Hide" : "History"}
        </Button>
      </div>
      {open ? (
        <ul className="mt-2 divide-y divide-border rounded-[var(--radius-card)] border border-border text-xs">
          {job.runs.length === 0 ? <li className="px-3 py-2 text-muted">No runs yet.</li> : null}
          {job.runs.map((run) => (
            <li key={run.id} className="flex flex-wrap items-center gap-2 px-3 py-1.5">
              <Badge tone={JOB_RUN_STATUS_TONES[run.status]}>{JOB_RUN_STATUS_LABELS[run.status]}</Badge>
              <span className="text-muted">{run.trigger}</span>
              <span className="text-foreground">{run.error ?? run.message ?? ""}</span>
              <span className="ml-auto text-muted">{relativeTime(run.created_at)}</span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
