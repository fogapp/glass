import { useState } from "react";

/** Changes one field of a draft — what a form section is handed. */
export type DraftSetter<T> = <K extends keyof T>(key: K, value: T[K]) => void;

/** A form's working copy of a record; `set` changes one field of it. */
export function useDraft<T extends object>(initial: T | (() => T)) {
  const [draft, setDraft] = useState<T>(initial);

  const set: DraftSetter<T> = (key, value) => {
    setDraft((current) => ({ ...current, [key]: value }));
  };

  return { draft, set, setDraft };
}
