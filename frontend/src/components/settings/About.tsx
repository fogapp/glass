import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { formatBytes } from "@/lib/format";
import { keys } from "@/lib/queryKeys";
import type { About as AboutInfo } from "@/types";
import { CopyField } from "@/components/ui/CopyField";
import { Fact, FactList } from "@/components/ui/FactList";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";

/**
 * Settings → About: which build
 * is running, and — because Glass is a fog app on a box someone else may
 * have set up — what it is running on. The revision is the fact people
 * actually come for, so it gets the copy button.
 */
export function About() {
  const about = useQuery({ queryKey: keys.about.detail(), queryFn: () => api.get<AboutInfo>("/about"), staleTime: 60_000 });

  if (about.isPending) return <LoadingState />;
  if (about.isError) {
    return <ErrorState message="Could not load instance details." onRetry={() => about.refetch()} />;
  }

  const info = about.data;
  const booted = new Date(info.booted_at);

  return (
    <div className="space-y-8">
      <section className="space-y-4">
        <SectionHeader title="Version" description="The build of Glass this household is running." />
        <div>
          <p className="mb-1 text-xs uppercase tracking-wide text-muted">Revision</p>
          {info.git_sha === "unknown" ? (
            <p className="font-mono text-sm text-muted">unknown</p>
          ) : (
            <CopyField value={info.git_sha} />
          )}
        </div>
        <FactList>
          <Fact label="Environment" value={info.environment} />
          <Fact label="Server started" value={`${booted.toLocaleString()} · up ${formatUptime(booted)}`} mono={false} />
          <Fact label="Time zone" value={info.time_zone} />
          <Fact label="Ruby" value={info.ruby_version} />
          <Fact label="Rails" value={info.rails_version} />
          <Fact label="PostgreSQL" value={info.postgres_version ?? "unknown"} />
        </FactList>
      </section>

      <section className="space-y-4">
        <SectionHeader title="This server" description="The machine Glass is running on, as the process sees it." />
        <FactList>
          <Fact label="Hostname" value={info.machine.hostname} />
          <Fact label="Platform" value={`${info.machine.os} · ${info.machine.arch}`} mono={false} />
          <Fact label="Kernel" value={info.machine.kernel} />
          <Fact label="CPUs" value={String(info.machine.cpus)} />
          <Fact label="Memory" value={formatBytes(info.machine.memory_total_bytes)} />
          <Fact
            label="Process"
            value={`pid ${info.machine.pid}${info.machine.user ? ` as ${info.machine.user}` : ""}${info.machine.containerized ? ", in a container" : ""}`}
            mono={false}
          />
        </FactList>
      </section>

      <section className="space-y-4">
        <SectionHeader title="Paths" description="Where this instance keeps its own small state. Telemetry lives in Postgres — see Storage." />
        <FactList className="md:grid-cols-2">
          <Fact label="State directory" value={info.storage.state_dir} />
          <Fact
            label="State disk"
            value={
              info.storage.total_bytes === null
                ? "unknown"
                : `${formatBytes(info.storage.free_bytes)} free of ${formatBytes(info.storage.total_bytes)}`
            }
            mono={false}
          />
        </FactList>
      </section>
    </div>
  );
}

/** "3d 4h" since a moment. */
function formatUptime(since: Date): string {
  const seconds = Math.max(0, Math.round((Date.now() - since.getTime()) / 1000));
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}
