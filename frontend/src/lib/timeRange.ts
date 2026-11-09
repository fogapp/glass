/**
 * The console's time range: a relative window ("1h", "24h", "7d") that
 * follows the clock, or an absolute [from, to] in Unix seconds. Relative
 * ranges are what the URL usually carries; brushing a chart makes an
 * absolute one.
 */

export interface TimeRange {
  /** "1h", "7d" — or null for an absolute range. */
  relative: string | null;
  from: number;
  to: number;
}

const UNITS: Record<string, number> = { m: 60, h: 3600, d: 86_400, w: 604_800 };

export const RANGE_PRESETS = [
  { key: "15m", label: "15 min" },
  { key: "1h", label: "1 hour" },
  { key: "3h", label: "3 hours" },
  { key: "12h", label: "12 hours" },
  { key: "24h", label: "24 hours" },
  { key: "3d", label: "3 days" },
  { key: "7d", label: "7 days" },
  { key: "30d", label: "30 days" },
] as const;

export const DEFAULT_RANGE = "3h";

/** Seconds in a relative window, or null when the text is not one. */
export function relativeSeconds(text: string): number | null {
  const match = /^(\d+)([mhdw])$/.exec(text.trim());
  if (!match) return null;
  return Number.parseInt(match[1] as string, 10) * (UNITS[match[2] as string] ?? 0);
}

/** A range from its URL form: "1h", or "1790000000-1790003600". */
export function parseRange(raw: string | null, now = Date.now() / 1000): TimeRange {
  if (raw) {
    const seconds = relativeSeconds(raw);
    if (seconds) return { relative: raw, from: Math.floor(now - seconds), to: Math.ceil(now) };
    const absolute = /^(\d+)-(\d+)$/.exec(raw);
    if (absolute) {
      const from = Number.parseInt(absolute[1] as string, 10);
      const to = Number.parseInt(absolute[2] as string, 10);
      if (to > from) return { relative: null, from, to };
    }
  }
  return parseRange(DEFAULT_RANGE, now);
}

export function serializeRange(range: TimeRange): string {
  return range.relative ?? `${range.from}-${range.to}`;
}

export function absoluteRange(from: number, to: number): TimeRange {
  return { relative: null, from: Math.floor(from), to: Math.ceil(to) };
}

/** The same window, shifted by its own width (the `[` and `]` keys). */
export function shiftRange(range: TimeRange, direction: -1 | 1): TimeRange {
  const width = range.to - range.from;
  return absoluteRange(range.from + direction * width, range.to + direction * width);
}

/** Twice as wide, centred on the same middle. */
export function zoomOut(range: TimeRange): TimeRange {
  const width = range.to - range.from;
  return absoluteRange(range.from - width / 2, range.to + width / 2);
}

/** What the range reads as in the picker. */
export function describeRange(range: TimeRange): string {
  if (range.relative) {
    const preset = RANGE_PRESETS.find((candidate) => candidate.key === range.relative);
    return preset ? `Last ${preset.label}` : `Last ${range.relative}`;
  }
  const from = new Date(range.from * 1000);
  const to = new Date(range.to * 1000);
  const sameDay = from.toDateString() === to.toDateString();
  const time = (date: Date) => date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const day = (date: Date) => date.toLocaleDateString([], { month: "short", day: "numeric" });
  return sameDay ? `${day(from)} ${time(from)} – ${time(to)}` : `${day(from)} ${time(from)} – ${day(to)} ${time(to)}`;
}

/** The window just before this one, for a comparison. */
export function previousRange(range: TimeRange): TimeRange {
  const width = range.to - range.from;
  return absoluteRange(range.from - width, range.from);
}
