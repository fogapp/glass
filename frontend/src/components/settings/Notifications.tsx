import { type FormEvent } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { useTestConnection } from "@/hooks/useTestConnection";
import { keys } from "@/lib/queryKeys";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { TestButton } from "@/components/settings/TestButton";
import { TestResultLine } from "@/components/settings/TestResultLine";
import type { Settings } from "@/types";

export function useSettings() {
  return useQuery({ queryKey: keys.settings.detail(), queryFn: () => api.get<Settings>("/app_setting") });
}

/** Settings › Notifications: where alerts go. ntfy on the fog network, typically. */
export function Notifications() {
  const settings = useSettings();
  return (
    <QueryState query={settings} errorMessage="Couldn't load settings.">
      {(data) => <NtfyForm settings={data} />}
    </QueryState>
  );
}

function NtfyForm({ settings }: { settings: Settings }) {
  const { draft, set } = useDraft({ ntfy_url: settings.ntfy_url ?? "", ntfy_topic: settings.ntfy_topic, ntfy_token: "" });
  const save = useFormMutation<Settings, void>({
    mutationFn: () => api.patch<Settings>("/app_setting", { ntfy_url: draft.ntfy_url.trim(), ntfy_topic: draft.ntfy_topic.trim(), ntfy_token: draft.ntfy_token || undefined }),
    meta: { invalidates: [keys.settings.all] },
    fallback: "Couldn't save.",
  });
  const test = useTestConnection("/app_setting/test_ntfy", keys.settings.all);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    save.mutate();
  };
  return (
    <form onSubmit={submit} className="max-w-xl space-y-4">
      <SectionHeader title="Push notifications" description="Monitors and incidents push through ntfy. On the fog network the server is http://ntfy." />
      <Input label="ntfy server" value={draft.ntfy_url} onChange={(event) => set("ntfy_url", event.target.value)} placeholder="http://ntfy" />
      <Input label="Topic" value={draft.ntfy_topic} onChange={(event) => set("ntfy_topic", event.target.value)} />
      <Input
        label="Access token"
        hint={settings.ntfy_token_set ? "A token is stored. Leave blank to keep it." : "Only if the topic needs one."}
        type="password"
        value={draft.ntfy_token}
        onChange={(event) => set("ntfy_token", event.target.value)}
        autoComplete="off"
      />
      <FormError message={save.errorMessage} />
      <div className="flex items-center gap-2">
        <FormFooter label="Save" pending={save.isPending} />
        <TestButton connection={test} disabled={!settings.ntfy_url} />
      </div>
      <TestResultLine ok={test.result?.ok ?? settings.last_test_ok} message={test.result?.message ?? settings.last_test_message} at={test.result ? null : settings.last_tested_at} />
    </form>
  );
}
