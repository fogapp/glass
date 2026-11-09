/**
 * What the failed queries of a page's batch said (`useGlassBatch`'s
 * `failures`). A failed query is never an empty chart, and never a row of
 * zeros: the figures it fed read as empty, and this says why.
 */
export function Failures({ messages }: { messages: string[] }) {
  if (messages.length === 0) return null;
  return (
    <p role="alert" className="rounded-[var(--radius-card)] border border-negative/40 bg-negative/10 px-3 py-2 text-xs text-negative">
      Part of this page could not be computed, and reads as empty: {messages.join(" · ")}
    </p>
  );
}
