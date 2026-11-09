import type { App } from "@/types";

/**
 * An app fog runs that has never reported: a third-party image, or one of
 * ours before its first deploy with a key. All Glass knows is what fog says.
 */
export function containerOnly(app: App): boolean {
  return app.first_seen_at === null && app.fog !== null;
}
