import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { CopyField } from "@/components/ui/CopyField";
import { FormError } from "@/components/ui/Form";
import { QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Select } from "@/components/ui/Select";
import { Passkeys } from "@/components/settings/Passkeys";
import { USER_ROLES, type User, type UserRole } from "@/types";

const ROLE_LABELS: Record<UserRole, string> = {
  admin: "Admin",
  member: "Member",
  guest: "Guest",
};

interface InviteResponse {
  code: string;
  role: UserRole;
  expires_at: string;
}

/** Household members and the invite door. Admins mint invite codes; a new
 *  member redeems one on the login page. */
export function Users() {
  const { user: me } = useAuth();
  const users = useQuery({
    queryKey: keys.users.list(),
    queryFn: () => api.get<User[]>("/users"),
  });
  const [role, setRole] = useState<UserRole>("member");
  const invite = useFormMutation({
    mutationFn: () => api.post<InviteResponse>("/invites", { role }),
    fallback: "Couldn't create an invite code.",
  });

  return (
    <div className="space-y-8">
      <section className="space-y-3">
        <SectionHeader title="Members" description="Everyone who can sign in to this household." />
        <QueryState query={users} errorMessage="Could not load members.">
          {(members) => (
          <ul className="divide-y divide-border">
            {members.map((user) => (
              <li key={user.id} className="flex items-center justify-between gap-4 py-3">
                <div className="min-w-0">
                  <p className="truncate text-sm text-foreground">{user.name}</p>
                  <p className="truncate text-xs text-muted">{user.email}</p>
                </div>
                <Badge tone={user.role === "admin" ? "info" : "neutral"}>{ROLE_LABELS[user.role]}</Badge>
              </li>
            ))}
          </ul>
          )}
        </QueryState>
      </section>

      <Passkeys />

      {me?.role === "admin" ? (
        <section className="space-y-3">
          <SectionHeader
            title="Invite someone"
            description="Codes work once and expire after seven days. Share the code; they enter it on the sign-in page."
          />
          <div className="flex flex-wrap items-end gap-3">
            <Select label="Role" name="role" value={role} onChange={(event) => setRole(event.target.value as UserRole)}>
              {USER_ROLES.map((value) => (
                <option key={value} value={value}>
                  {ROLE_LABELS[value]}
                </option>
              ))}
            </Select>
            <Button onClick={() => invite.mutate()} disabled={invite.isPending}>
              {invite.isPending ? "Creating…" : "Create invite code"}
            </Button>
          </div>
          <FormError message={invite.errorMessage} />
          {invite.data ? (
            <div className="max-w-md space-y-1">
              <CopyField value={invite.data.code} />
              <p className="text-xs text-muted">
                {ROLE_LABELS[invite.data.role]} · expires {new Date(invite.data.expires_at).toLocaleDateString()}
              </p>
            </div>
          ) : null}
        </section>
      ) : null}
    </div>
  );
}
