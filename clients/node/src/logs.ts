import { format } from "node:util";

type Level = "debug" | "info" | "warn" | "error";
type Method = "debug" | "log" | "info" | "warn" | "error";

const LEVEL_OF: Record<Method, Level> = { debug: "debug", log: "info", info: "info", warn: "warn", error: "error" };
/** `[fleet] task released` — an app's own convention for saying which part of it is speaking. */
const PREFIX = /^\[([a-z][\w.-]{0,30})\]\s*/i;

/**
 * Everything the process writes with `console.*`, as log records — a process
 * with no logger of its own logs this way, and inside a run the line carries
 * the run's trace. The console still prints exactly what it printed before;
 * this only listens. A leading `[word]` becomes the record's source.
 *
 * Returns the function that puts the console back.
 */
export function captureConsole(emit: (level: Level, message: string, source: string) => void): () => void {
  const original: Partial<Record<Method, (...args: unknown[]) => void>> = {};
  let emitting = false;
  for (const method of Object.keys(LEVEL_OF) as Method[]) {
    const write = console[method].bind(console) as (...args: unknown[]) => void;
    original[method] = console[method] as (...args: unknown[]) => void;
    console[method] = (...args: unknown[]) => {
      write(...args);
      // Whatever reporting a line does, it must not become another line.
      if (emitting) return;
      emitting = true;
      try {
        const text = format(...args);
        const match = PREFIX.exec(text);
        emit(LEVEL_OF[method], match ? text.slice(match[0].length) : text, match ? match[1]!.toLowerCase() : "console");
      } catch {
        /* a line that cannot be formatted is not worth an exception */
      } finally {
        emitting = false;
      }
    };
  }
  return () => {
    for (const method of Object.keys(original) as Method[]) console[method] = original[method] as never;
  };
}
