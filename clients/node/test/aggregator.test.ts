import assert from "node:assert/strict";
import { test } from "node:test";
import { Aggregator } from "../src/index.ts";

test("folds calls into one record per series per ten-second window", () => {
  const aggregator = new Aggregator();
  aggregator.counter("ai.calls", 1, { model: "a", purpose: "turn" }, undefined, 1005);
  aggregator.counter("ai.calls", 2, { purpose: "turn", model: "a" }, undefined, 1009);
  aggregator.counter("ai.calls", 1, { model: "b" }, undefined, 1009);
  aggregator.counter("ai.calls", 1, { model: "a", purpose: "turn" }, undefined, 1012);

  assert.deepEqual(aggregator.drain(1010), [
    { t: "metric", ts: 1000, name: "ai.calls", kind: "counter", n: 2, sum: 3, tags: { model: "a", purpose: "turn" } },
    { t: "metric", ts: 1000, name: "ai.calls", kind: "counter", n: 1, sum: 1, tags: { model: "b" } },
  ]);
  assert.deepEqual(aggregator.drain(1015), [], "the open window waits");
  assert.equal(aggregator.drain(1015, true).length, 1, "unless this is the last flush");
});

test("summarizes a gauge and sketches a distribution", () => {
  const aggregator = new Aggregator();
  for (const value of [3, 9, 5]) aggregator.gauge("node.handles", value, undefined, undefined, 2000);
  for (const value of [100, 100, 1]) aggregator.dist("ai.ttft", value, { model: "a" }, "ms", 2000);
  const [gauge, dist] = aggregator.drain(2010);
  assert.deepEqual(gauge, { t: "metric", ts: 2000, name: "node.handles", kind: "gauge", n: 3, sum: 17, min: 3, max: 9, last: 5 });
  assert.deepEqual(dist, { t: "metric", ts: 2000, name: "ai.ttft", kind: "dist", unit: "ms", tags: { model: "a" }, n: 3, sum: 201, min: 1, max: 100, last: 1, sk: [0, 1, 233, 2] });
});

test("counts distinct members, drops what it cannot name, and bounds the series", () => {
  const aggregator = new Aggregator(2);
  aggregator.set("sessions", "a", undefined, 3000);
  aggregator.set("sessions", "a", undefined, 3000);
  aggregator.set("sessions", "b", undefined, 3000);
  aggregator.counter("not a name", 1, undefined, undefined, 3000);
  aggregator.counter("x", Number.NaN, undefined, undefined, 3000);
  aggregator.counter("one", 1, undefined, undefined, 3000);
  aggregator.counter("two", 1, undefined, undefined, 3000);
  const records = aggregator.drain(3010);
  assert.deepEqual(records.map((record) => [record.name, record.n]), [["sessions", 2], ["one", 1]]);
  assert.equal(aggregator.takeDropped(), 2);
  assert.equal(aggregator.takeDropped(), 0);
});

test("bounds tags: null drops the tag, long values are cut", () => {
  const aggregator = new Aggregator();
  aggregator.counter("x", 1, { a: null, b: "y".repeat(500), c: 3 }, undefined, 4000);
  const [record] = aggregator.drain(4010);
  assert.deepEqual(Object.keys(record!.tags!), ["b", "c"]);
  assert.equal(record!.tags!.b!.length, 200);
  assert.equal(record!.tags!.c, "3");
});
