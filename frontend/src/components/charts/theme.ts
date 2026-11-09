import { useSyncExternalStore } from "react";

/**
 * The chart tokens, read from the document so canvases and uPlot draw with
 * the same colors the CSS uses. Re-read when the theme flips: a canvas does
 * not repaint itself when a custom property changes.
 */
export interface ChartTheme {
  series: string[];
  heat: string[];
  grid: string;
  crosshair: string;
  muted: string;
  foreground: string;
  surface: string;
  primary: string;
  positive: string;
  negative: string;
  warning: string;
  mono: string;
  sans: string;
}

const SLOTS = 8;
const HEAT_STEPS = 7;

export function readChartTheme(): ChartTheme {
  const style = getComputedStyle(document.documentElement);
  const token = (name: string) => style.getPropertyValue(name).trim();
  return {
    series: Array.from({ length: SLOTS }, (_, index) => token(`--color-series-${index + 1}`)),
    heat: Array.from({ length: HEAT_STEPS }, (_, index) => token(`--color-heat-${index + 1}`)),
    grid: token("--color-grid"),
    crosshair: token("--color-crosshair"),
    muted: token("--color-muted"),
    foreground: token("--color-foreground"),
    surface: token("--color-surface"),
    primary: token("--color-primary"),
    positive: token("--color-positive"),
    negative: token("--color-negative"),
    warning: token("--color-warning"),
    mono: token("--font-mono"),
    sans: token("--font-sans"),
  };
}

// One theme for every chart on the page: read once, re-read when the
// document's theme attribute or class flips, shared by one observer.
let current: ChartTheme | null = null;
let currentKey = "";
const listeners = new Set<() => void>();
let observer: MutationObserver | null = null;

function refresh(): boolean {
  const next = readChartTheme();
  const key = JSON.stringify(next);
  if (current && key === currentKey) return false;
  current = next;
  currentKey = key;
  return true;
}

function snapshot(): ChartTheme {
  if (!current) refresh();
  return current!;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  if (!observer) {
    // The theme may have flipped while nobody was listening.
    refresh();
    observer = new MutationObserver(() => {
      if (refresh()) for (const notify of listeners) notify();
    });
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "class"] });
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      observer?.disconnect();
      observer = null;
    }
  };
}

export function useChartTheme(): ChartTheme {
  return useSyncExternalStore(subscribe, snapshot);
}

/** The series color for a 1-based slot (an app's `color_slot`) or a 0-based index. */
export function slotColor(theme: ChartTheme, slot: number): string {
  return theme.series[((slot % SLOTS) + SLOTS) % SLOTS] ?? theme.series[0]!;
}

const resolved = new Map<string, [number, number, number]>();

/**
 * A color as r, g, b — whatever CSS form the token is in (hex, oklch, a
 * name), resolved by the canvas itself. A canvas rejects a fillStyle it
 * cannot parse and silently keeps the previous one, which is how an
 * unsupported `color-mix()` once painted every area fill solid green.
 */
export function rgb(color: string): [number, number, number] {
  const cached = resolved.get(color);
  if (cached) return cached;
  let out: [number, number, number] = [128, 128, 128];
  const hex = /^#([0-9a-f]{6})$/i.exec(color.trim());
  if (hex) {
    const value = Number.parseInt(hex[1]!, 16);
    out = [(value >> 16) & 255, (value >> 8) & 255, value & 255];
  } else if (typeof document !== "undefined") {
    const ctx = document.createElement("canvas").getContext("2d");
    if (ctx) {
      ctx.fillStyle = "#000000";
      ctx.fillStyle = color;
      const normalized = String(ctx.fillStyle);
      const asHex = /^#([0-9a-f]{6})/i.exec(normalized);
      const asRgb = /^rgba?\((\d+),\s*(\d+),\s*(\d+)/.exec(normalized);
      if (asHex) {
        const value = Number.parseInt(asHex[1]!, 16);
        out = [(value >> 16) & 255, (value >> 8) & 255, value & 255];
      } else if (asRgb) out = [Number(asRgb[1]), Number(asRgb[2]), Number(asRgb[3])];
    }
  }
  resolved.set(color, out);
  return out;
}

/** A color with alpha, for area washes and hover rings. */
export function withAlpha(color: string, alpha: number): string {
  const [r, g, b] = rgb(color);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/** The category of a profile frame, as a stable color. */
export function categoryColor(theme: ChartTheme, category: string): string {
  switch (category) {
    case "app":
      return theme.series[0]!;
    case "gem":
      return theme.series[6]!;
    // The runtime's own code, whichever runtime it is.
    case "ruby":
    case "node":
      return theme.series[3]!;
    case "native":
      return theme.series[2]!;
    default:
      return theme.muted;
  }
}
