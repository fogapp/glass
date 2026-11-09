import { useEffect, useRef } from "react";
import { cn } from "@/lib/cn";

export interface TabDescriptor<K extends string> {
  key: K;
  label: string;
}

/**
 * A row of tabs across the top of a page section. Controlled and
 * content-free: the page decides what each tab shows; this only renders the
 * strip and announces it properly (tablist semantics, arrow-key movement).
 *
 * The strip scrolls sideways rather than wrapping: twelve settings tabs on a
 * phone are a swipe, not a stack, and the active one is scrolled into view
 * so a deep link never lands on a tab that is off the edge.
 */
export function Tabs<K extends string>({
  tabs,
  active,
  onChange,
  label,
}: {
  tabs: readonly TabDescriptor<K>[];
  active: K;
  onChange: (key: K) => void;
  label: string;
}) {
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const list = listRef.current;
    if (!list || list.scrollWidth <= list.clientWidth) return;
    list.querySelector<HTMLButtonElement>("[aria-selected=true]")?.scrollIntoView({ block: "nearest", inline: "center" });
  }, [active]);

  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key !== "ArrowRight" && event.key !== "ArrowLeft") return;
    event.preventDefault();
    const index = tabs.findIndex((tab) => tab.key === active);
    const step = event.key === "ArrowRight" ? 1 : -1;
    const next = tabs[(index + step + tabs.length) % tabs.length];
    onChange(next.key);
    listRef.current?.querySelectorAll<HTMLButtonElement>("[role=tab]")[
      (index + step + tabs.length) % tabs.length
    ]?.focus();
  }

  return (
    <div
      ref={listRef}
      role="tablist"
      aria-label={label}
      className="scrollbar-none -mb-px flex gap-1 overflow-x-auto"
      onKeyDown={onKeyDown}
    >
      {tabs.map((tab) => {
        const selected = tab.key === active;
        return (
          <button
            key={tab.key}
            type="button"
            role="tab"
            aria-selected={selected}
            // Roving focus: Tab lands on the active tab, arrows move between
            // them — the tablist is one stop, not one per tab.
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(tab.key)}
            className={cn(
              "h-10 shrink-0 whitespace-nowrap border-b-2 px-3 text-sm transition-colors lg:h-9",
              selected
                ? "border-primary font-medium text-foreground"
                : "border-transparent text-muted hover:border-border hover:text-foreground",
            )}
          >
            {tab.label}
          </button>
        );
      })}
    </div>
  );
}
