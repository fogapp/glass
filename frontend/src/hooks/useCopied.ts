import { useState } from "react";

/**
 * Copy text to the clipboard and flash "copied" for two seconds — the only
 * state a copy button carries.
 */
export function useCopied(): { copied: boolean; copy: (value: string) => Promise<void> } {
  const [copied, setCopied] = useState(false);

  async function copy(value: string) {
    await navigator.clipboard.writeText(value);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2000);
  }

  return { copied, copy };
}
