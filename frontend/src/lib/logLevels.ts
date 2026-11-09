/** A log line's level as a text tone, the same in every list of lines. */
export const LEVEL_TONES: Readonly<Record<string, string>> = { fatal: "text-negative", error: "text-negative", warn: "text-warning" };

export function levelTone(level: unknown): string {
  return LEVEL_TONES[String(level)] ?? "text-muted";
}

/** A level's tone in a list of lines, or (`chip`) as a toggle's border, fill and text. */
export function levelClass(level: string, chip: boolean): string {
  switch (level) {
    case "error":
    case "fatal":
      return chip ? "border-negative/40 bg-negative/10 text-negative" : "text-negative";
    case "warn":
      return chip ? "border-warning/40 bg-warning/10 text-warning" : "text-warning";
    case "debug":
      return chip ? "border-border bg-surface-raised text-muted" : "text-muted/70";
    default:
      return chip ? "border-primary/30 bg-primary/10 text-foreground" : "text-muted";
  }
}
