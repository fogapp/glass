import { useLayoutEffect, useState } from "react";

/**
 * An element's content box as state, kept current by a ResizeObserver.
 * Hand the returned ref to the element; it follows the element if React
 * swaps it for another.
 */
export function useElementSize<T extends HTMLElement>(): [(element: T | null) => void, { width: number; height: number }] {
  const [element, setElement] = useState<T | null>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });

  useLayoutEffect(() => {
    if (!element) return;
    const update = () =>
      setSize((current) => (current.width === element.clientWidth && current.height === element.clientHeight ? current : { width: element.clientWidth, height: element.clientHeight }));
    update();
    const observer = new ResizeObserver(update);
    observer.observe(element);
    return () => observer.disconnect();
  }, [element]);

  return [setElement, size];
}
