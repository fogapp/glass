import { describe, expect, it } from "vitest";
import { safeReturnPath } from "./returnPath";

describe("safeReturnPath", () => {
  it.each([
    ["/traces", "/traces"],
    ["/explore?q=status%3A500", "/explore?q=status%3A500"],
    ["//evil.example", "/"],
    ["/\\evil.example", "/"],
    ["https://evil.example", "/"],
    ["", "/"],
    [null, "/"],
    [undefined, "/"],
  ])("%s → %s", (raw, expected) => {
    expect(safeReturnPath(raw)).toBe(expected);
  });
});
