import { useEffect, useState } from "react";

/**
 * The value as of `delay` ms after it stopped changing. What lets a slider
 * drag feel instant locally while the expensive thing keyed off it (a
 * ranking pass, a search) fires once per pause instead of once per pixel.
 */
export function useDebouncedValue<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delay);
    return () => window.clearTimeout(timer);
  }, [value, delay]);

  return debounced;
}
