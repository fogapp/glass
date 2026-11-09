/** True while a key press belongs to a text field (or carries a modifier), not to the page's shortcuts. */
export function isTyping(event: KeyboardEvent): boolean {
  const target = event.target as HTMLElement | null;
  if (!target) return false;
  const tag = target.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable || event.metaKey || event.ctrlKey || event.altKey;
}
