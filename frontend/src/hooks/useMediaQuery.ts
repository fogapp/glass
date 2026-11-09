import { useEffect, useState } from "react";

/**
 * Whether a CSS media query currently matches, as state.
 *
 * Tailwind's responsive classes cover almost everything, but not a
 * `table-fixed` layout: a column hidden with `display: none` still holds its
 * share of the table's width, and the space it was given goes nowhere. A
 * fluid table has to drop the column from the array instead — which means
 * asking JavaScript the same question the breakpoint asks CSS.
 */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => window.matchMedia?.(query).matches ?? false);

  useEffect(() => {
    const list = window.matchMedia?.(query);
    if (!list) return;
    const update = () => setMatches(list.matches);
    update();
    list.addEventListener("change", update);
    return () => list.removeEventListener("change", update);
  }, [query]);

  return matches;
}

/** Tailwind's own breakpoints, so a JS check and a `lg:` class can't drift. */
export const BREAKPOINTS = {
  md: "(min-width: 48rem)",
  lg: "(min-width: 64rem)",
  xl: "(min-width: 80rem)",
} as const;
