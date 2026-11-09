import { useState } from "react";
import { X } from "lucide-react";
import { functionNeedsField } from "@/lib/workFields";

const SELECT = "h-7 rounded-[var(--radius-control)] border border-border bg-input px-1.5 font-mono text-xs text-foreground";

/**
 * What a chart shows: the computes so far, and a function (with the field
 * it takes, if any) to add. A pick that the source no longer offers falls
 * back to the first that it does — read from the lists, never stored.
 */
export function ComputeEditor({
  computes,
  source,
  functions,
  measures,
  dimensions,
  metricKind,
  onChange,
}: {
  computes: string[];
  source: string;
  functions: string[];
  measures: string[];
  dimensions: string[];
  metricKind?: string;
  onChange: (next: string[]) => void;
}) {
  const [pickedFn, setFn] = useState("");
  const [pickedField, setField] = useState("");
  const [pickedOver, setOver] = useState("");
  const fn = functions.includes(pickedFn) ? pickedFn : (functions[0] ?? "count");
  const needs = functionNeedsField(fn, source);
  const options = needs === "dimension" ? dimensions : measures;
  const field = options.includes(pickedField) ? pickedField : (options[0] ?? "");
  const over = measures.includes(pickedOver) ? pickedOver : (measures[1] ?? measures[0] ?? "");
  const text = needs === null ? fn : needs === "pair" ? `${fn}(${field}, ${over})` : `${fn}(${field})`;
  const add = () => {
    if (!computes.includes(text)) onChange([...computes, text]);
  };
  return (
    <div className="flex flex-wrap items-center gap-1">
      <span className="text-muted">show</span>
      {computes.map((compute) => (
        <span key={compute} className="flex items-center gap-1 rounded-[var(--radius-control)] border border-primary/30 bg-primary/10 px-1.5 py-0.5 font-mono text-xs text-foreground">
          {compute}
          <button type="button" aria-label={`Remove ${compute}`} onClick={() => onChange(computes.filter((entry) => entry !== compute))} className="text-muted hover:text-foreground">
            <X className="h-3 w-3" aria-hidden />
          </button>
        </span>
      ))}
      {computes.length === 0 && metricKind ? <span className="font-mono text-xs text-muted">(default for a {metricKind})</span> : null}
      <select value={fn} onChange={(event) => setFn(event.target.value)} aria-label="Function" className={SELECT}>
        {functions.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
      {needs !== null ? (
        <select value={field} onChange={(event) => setField(event.target.value)} aria-label="Field" className={SELECT}>
          {options.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
      ) : null}
      {needs === "pair" ? (
        <>
          <span className="text-muted">over</span>
          <select value={over} onChange={(event) => setOver(event.target.value)} aria-label="Divided by" className={SELECT}>
            {measures.map((option) => (
              <option key={option} value={option}>
                {option}
              </option>
            ))}
          </select>
        </>
      ) : null}
      <button type="button" onClick={add} className="h-7 rounded-[var(--radius-control)] border border-border px-2 text-xs text-foreground hover:bg-surface-raised">
        + add
      </button>
    </div>
  );
}
