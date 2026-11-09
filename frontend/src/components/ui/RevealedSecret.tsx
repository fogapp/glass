import type { ReactNode } from "react";
import { Button } from "./Button";
import { CopyField } from "./CopyField";

/**
 * A credential shown the one time the server will ever send it. It stays up
 * until the person says they have it, and `children` says where it goes.
 */
export function RevealedSecret({
  name,
  secret,
  onDismiss,
  heading,
  children,
}: {
  name: string;
  /** What to say above the secret, when "Copy the token for …" is the wrong word for it. */
  heading?: ReactNode;
  secret: string;
  onDismiss: () => void;
  children?: ReactNode;
}) {
  return (
    <div className="space-y-2 rounded-[var(--radius-card)] border border-warning/40 bg-warning/10 p-4">
      <p className="text-sm font-medium text-foreground">{heading ?? <>Copy the token for “{name}” now — it won't be shown again.</>}</p>
      <CopyField value={secret} />
      {children}
      <Button size="sm" variant="ghost" onClick={onDismiss}>
        I've copied it
      </Button>
    </div>
  );
}
