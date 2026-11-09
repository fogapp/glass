import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { Sketch } from "../src/index.ts";

// The conformance kit every client shares (spec/fixtures/ingest): the server's
// suite and the gem's read the same file.
const kit = JSON.parse(readFileSync(new URL("../../../spec/fixtures/ingest/sketch.json", import.meta.url), "utf8"));

test("maps every pinned value to its index", () => {
  for (const { value, index } of kit.indexes) assert.equal(Sketch.indexFor(value), index, `index for ${value}`);
});

test("folds values into the pinned wire arrays", () => {
  for (const { values, sk, n } of [...kit.sketches, ...(kit.folded ?? [])]) {
    const sketch = new Sketch();
    for (const value of values) sketch.add(value);
    assert.deepEqual(sketch.toPairs(), sk);
    assert.equal(sketch.count, n);
  }
});

test("folds the lowest buckets up rather than send more than the server takes", () => {
  const sketch = new Sketch();
  for (let index = 0; index < Sketch.MAX_BUCKETS + 10; index += 1) sketch.add(Math.exp((index + 0.5) * Sketch.LOG_GAMMA));
  const pairs = sketch.toPairs();
  assert.equal(pairs.length, Sketch.MAX_BUCKETS * 2);
  assert.equal(pairs[1], 11);
});
