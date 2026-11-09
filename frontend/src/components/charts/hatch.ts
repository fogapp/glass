/** A hatch in a token's colour: the mark for time that was not the app's — a person deciding — or that nothing accounts for. */
export function hatch(color: string): string {
  return `repeating-linear-gradient(135deg, ${color} 0 3px, transparent 3px 6px)`;
}
