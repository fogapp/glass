/**
 * Whether a render error is a lazily loaded page failing to arrive rather
 * than a page crashing. The usual cause is a deploy: the tab still holds the
 * old index, whose hashed chunks the new release no longer serves. Retrying
 * cannot help — `React.lazy` keeps the rejected import — so the boundary
 * offers a reload instead of "Try again".
 *
 * Browsers word the failure differently: Chromium "Failed to fetch
 * dynamically imported module", Firefox "error loading dynamically imported
 * module", Safari "Importing a module script failed"; Vite's CSS preload
 * says "Unable to preload CSS".
 */
const CHUNK_LOAD_MESSAGES = [
  /failed to fetch dynamically imported module/i,
  /error loading dynamically imported module/i,
  /importing a module script failed/i,
  /unable to preload css/i,
];

export function isChunkLoadError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  if (error.name === "ChunkLoadError") return true;
  return CHUNK_LOAD_MESSAGES.some((pattern) => pattern.test(error.message));
}
