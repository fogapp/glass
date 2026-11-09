import { useEffect, useState } from "react";

/**
 * Now, in Unix seconds, stable between renders: fixed when the component
 * mounts, or advanced every `everyMs` — so a window built on it is not a
 * new query key on every render.
 */
export function useNow(everyMs?: number): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    if (!everyMs) return;
    const timer = window.setInterval(() => setNow(Math.floor(Date.now() / 1000)), everyMs);
    return () => window.clearInterval(timer);
  }, [everyMs]);
  return now;
}
