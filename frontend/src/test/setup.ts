import "@testing-library/jest-dom/vitest";

// Node 22+ ships its own `localStorage` global, which without
// --localstorage-file is undefined — and it shadows jsdom's. Anything that
// signs in (tokenStore, useAuth) needs a real one, so give the test window a
// plain in-memory Storage when the runtime left a hole.
if (typeof globalThis.localStorage === "undefined") {
  const data = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return data.size;
    },
    clear: () => data.clear(),
    getItem: (key) => data.get(key) ?? null,
    key: (index) => Array.from(data.keys())[index] ?? null,
    removeItem: (key) => void data.delete(key),
    setItem: (key, value) => void data.set(key, String(value)),
  };
  Object.defineProperty(globalThis, "localStorage", { value: storage, configurable: true });
}
