import { Button } from "@/components/ui/Button";
import type { TestConnection } from "@/hooks/useTestConnection";

/** The Test button every connection in Settings has. */
export function TestButton({
  connection,
  disabled = false,
  label = "Test",
}: {
  connection: TestConnection;
  disabled?: boolean;
  label?: string;
}) {
  return (
    <Button type="button" size="sm" variant="secondary" onClick={connection.run} disabled={disabled || connection.pending}>
      {connection.pending ? "Testing…" : label}
    </Button>
  );
}
