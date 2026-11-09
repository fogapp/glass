/**
 * Numbers as the console shows them. One function per question, so a
 * figure reads the same wherever it appears.
 */

/** A figure from a query's row: a missing cell is zero. */
export function num(cell: unknown): number {
  return Number(cell ?? 0);
}

/** A figure from a query's row that may be missing: null stays null, so it shows as "—". */
export function optionalNum(cell: unknown): number | null {
  return cell === null || cell === undefined ? null : Number(cell);
}

/** 1,284 · 12.9K · 4.2M — a count, compact past a thousand. */
export function formatCount(value: number | null | undefined, digits = 1): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  const abs = Math.abs(value);
  if (abs < 1000) return Number.isInteger(value) ? value.toLocaleString() : trimZeros(value.toFixed(abs < 10 ? 2 : 1));
  const units = ["K", "M", "B"];
  let scaled = value;
  let unit = -1;
  while (Math.abs(scaled) >= 1000 && unit < units.length - 1) {
    scaled /= 1000;
    unit += 1;
  }
  return `${scaled.toFixed(Math.abs(scaled) < 10 ? digits : 0)}${units[unit]}`;
}

/** "2.50" → "2.5", "3.00" → "3": a figure without the noise. */
function trimZeros(text: string): string {
  return text.includes(".") ? text.replace(/\.?0+$/, "") : text;
}

/** 842ms · 1.20s · 3m 04s — a duration given in milliseconds. */
export function formatMs(ms: number | null | undefined): string {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return "—";
  if (ms < 1) return `${ms.toFixed(2)}ms`;
  if (ms < 10) return `${ms.toFixed(1)}ms`;
  if (ms < 1000) return `${Math.round(ms)}ms`;
  const seconds = ms / 1000;
  if (seconds < 60) return `${seconds.toFixed(seconds < 10 ? 2 : 1)}s`;
  const minutes = Math.floor(seconds / 60);
  const rest = Math.round(seconds % 60);
  if (minutes < 60) return `${minutes}m ${String(rest).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

/** 1.4 GB from a byte count. */
export function formatBytes(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined || !Number.isFinite(bytes)) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (Math.abs(value) >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}`;
}

/** 0.0725 → 7.3% */
export function formatPercent(ratio: number | null | undefined, digits = 1): string {
  if (ratio === null || ratio === undefined || !Number.isFinite(ratio)) return "—";
  const pct = ratio * 100;
  return `${pct.toFixed(pct !== 0 && pct < 0.1 ? 2 : digits)}%`;
}

/** $0.0042 · $1.28 · $412 — money, with the digits a small sum needs to be told from nothing. */
export function formatUsd(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  const abs = Math.abs(value);
  if (abs === 0) return "$0";
  if (abs < 0.01) return `$${trimZeros(value.toFixed(4))}`;
  if (abs < 100) return `$${value.toFixed(2)}`;
  return `$${formatCount(Math.round(value))}`;
}

/** 12.4/s · 0.8/min — a rate given per second. */
export function formatRate(perSecond: number | null | undefined): string {
  if (perSecond === null || perSecond === undefined || !Number.isFinite(perSecond)) return "—";
  if (perSecond >= 1) return `${formatCount(perSecond)}/s`;
  const perMinute = perSecond * 60;
  if (perMinute >= 1) return `${perMinute.toFixed(1)}/min`;
  return `${(perSecond * 3600).toFixed(1)}/h`;
}

/** A value in the unit a query answered with. */
export function formatUnit(value: number | null | undefined, unit: string | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  switch (unit) {
    case "ms":
      return formatMs(value);
    case "s":
      return formatMs(value * 1000);
    case "bytes":
      return formatBytes(value);
    case "ratio":
      return formatPercent(value);
    case "percent":
      return `${value.toFixed(value < 10 ? 1 : 0)}%`;
    case "per_second":
      return formatRate(value);
    case "score":
      return value.toFixed(2);
    case "usd":
      return formatUsd(value);
    default:
      return formatCount(value);
  }
}

/** An axis tick in a unit: shorter than the full form. */
export function formatTick(value: number, unit: string | null | undefined): string {
  switch (unit) {
    case "ms":
      return value >= 1000 ? `${(value / 1000).toFixed(value >= 10_000 ? 0 : 1)}s` : `${value >= 100 ? Math.round(value) : value.toFixed(value < 10 ? 1 : 0)}ms`;
    case "bytes":
      return formatBytes(value);
    case "ratio":
      return `${Math.round(value * 100)}%`;
    case "percent":
      return `${Math.round(value)}%`;
    case "usd":
      return formatUsd(value);
    default:
      return formatCount(value, 0);
  }
}

/** A Unix-seconds timestamp as a wall-clock time appropriate to a range. */
export function formatTime(seconds: number, spanSeconds: number): string {
  const date = new Date(seconds * 1000);
  if (spanSeconds <= 86_400 * 2) return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (spanSeconds <= 86_400 * 14) return date.toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" });
  return date.toLocaleDateString([], { month: "short", day: "numeric" });
}

/** A Unix-seconds timestamp, whole. */
export function formatDateTime(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined) return "—";
  return new Date(seconds * 1000).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/**
 * 09:41:07 · 09:41:07 PM — a Unix-seconds timestamp's time of day, for rows
 * that already sit under a date. Assembled from parts, so no locale's
 * separators leak in; the hour keeps the locale's 12/24h convention, as
 * formatDateTime and formatTime do.
 */
export function formatClock(seconds: number | null | undefined, locale?: string): string {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return "—";
  const parts = new Intl.DateTimeFormat(locale ?? [], { hour: "2-digit", minute: "2-digit", second: "2-digit" }).formatToParts(new Date(seconds * 1000));
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value;
  const clock = [part("hour"), part("minute"), part("second")].map((value) => (value ?? "").padStart(2, "0")).join(":");
  const period = part("dayPeriod");
  return period ? `${clock} ${period}` : clock;
}

/** 3m ago · 2h ago — from Unix seconds. */
export function formatAgo(seconds: number | null | undefined, now = Date.now() / 1000): string {
  if (seconds === null || seconds === undefined) return "never";
  const delta = Math.max(0, now - seconds);
  if (delta < 45) return "just now";
  if (delta < 3600) return `${Math.round(delta / 60)}m ago`;
  if (delta < 86_400 * 2) return `${Math.round(delta / 3600)}h ago`;
  return `${Math.round(delta / 86_400)}d ago`;
}

/** The first characters of a git SHA, the way fog shows one. */
export function shortSha(sha: string | null | undefined): string {
  return sha ? sha.slice(0, 7) : "—";
}
