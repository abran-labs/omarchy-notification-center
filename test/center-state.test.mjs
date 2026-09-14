import test from "node:test";
import assert from "node:assert/strict";

import * as CenterState from "../CenterState.js";

const normalUrgency = 1;

function row(overrides = {}) {
  return {
    id: 7,
    originalId: 7,
    app: "vesktop",
    appIcon: "vesktop",
    summary: "hi",
    body: "hello",
    image: "",
    glyph: "",
    execArgv: "",
    urgency: normalUrgency,
    expireTimeout: 0,
    timestamp: 1700000000000,
    ...overrides,
  };
}

test("keyOf identifies by timestamp+originalId, not id alone", () => {
  const a = row({ id: 1, originalId: 1, timestamp: 1000 });
  const b = row({ id: 1, originalId: 1, timestamp: 2000 });
  assert.notEqual(CenterState.keyOf(a), CenterState.keyOf(b));
  const c = row({ id: 99, originalId: 1, timestamp: 1000 });
  assert.equal(CenterState.keyOf(a), CenterState.keyOf(c));
});

test("normalizeEntry coerces types and rejects unusable rows", () => {
  const out = CenterState.normalizeEntry(
    { originalId: "12", timestamp: "1700000000000", app: "x", urgency: undefined },
    normalUrgency,
  );
  assert.equal(out.originalId, 12);
  assert.equal(out.timestamp, 1700000000000);
  assert.equal(out.urgency, normalUrgency);
  assert.equal(CenterState.normalizeEntry(null, normalUrgency), null);
  assert.equal(CenterState.normalizeEntry({ app: "x" }, normalUrgency), null);
  assert.equal(
    CenterState.normalizeEntry({ originalId: 1, timestamp: 0 }, normalUrgency),
    null,
  );
});

test("parseConcatenatedLines isolates malformed files", () => {
  const raw = [
    JSON.stringify(row({ originalId: 1, timestamp: 1000 })),
    "{torn write",
    "",
    JSON.stringify(row({ originalId: 2, timestamp: 2000 })),
    "[1,2,3]",
  ].join("\n");
  const out = CenterState.parseConcatenatedLines(raw, normalUrgency);
  assert.deepEqual(
    out.map((e) => e.originalId),
    [1, 2],
  );
});

test("merge defaults rows to unread, honors readKeys", () => {
  const merged = CenterState.mergeEntries({
    diskRows: [row({ originalId: 1, timestamp: 1000 })],
    liveRows: [],
    readKeys: {},
    dismissedKeys: {},
    archived: [],
  });
  assert.equal(merged.length, 1);
  assert.equal(merged[0].unread, true);

  const read = CenterState.mergeEntries({
    diskRows: [row({ originalId: 1, timestamp: 1000 })],
    liveRows: [],
    readKeys: { [CenterState.keyOf(row({ originalId: 1, timestamp: 1000 }))]: true },
    dismissedKeys: {},
    archived: [],
  });
  assert.equal(read[0].unread, false);
});

test("merge drops tombstoned keys even when the file is still on disk", () => {
  const disk = [row({ originalId: 5, timestamp: 5000 })];
  const key = CenterState.keyOf(disk[0]);
  const merged = CenterState.mergeEntries({
    diskRows: disk,
    liveRows: [],
    readKeys: {},
    dismissedKeys: { [key]: true },
    archived: [],
  });
  assert.equal(merged.length, 0);
  // And it stays gone on the next poll with the same on-disk state.
  const again = CenterState.mergeEntries({
    diskRows: disk,
    liveRows: [],
    readKeys: {},
    dismissedKeys: { [key]: true },
    archived: [],
  });
  assert.equal(again.length, 0);
});

test("merge includes live popup rows missing from disk, newest-first, capped", () => {
  const merged = CenterState.mergeEntries(
    {
      diskRows: [row({ originalId: 1, timestamp: 1000 })],
      liveRows: [
        row({ originalId: 2, timestamp: 2000 }),
        row({ originalId: 3, timestamp: 3000 }),
      ],
      readKeys: {},
      dismissedKeys: {},
      archived: [],
    },
    { rowLimit: 2 },
  );
  assert.equal(merged.length, 2);
  assert.deepEqual(
    merged.map((e) => e.timestamp),
    [3000, 2000],
  );
});

test("merge dedupes disk/live copies of the same key", () => {
  const merged = CenterState.mergeEntries({
    diskRows: [row({ originalId: 9, timestamp: 9000, summary: "disk" })],
    liveRows: [row({ originalId: 9, timestamp: 9000, summary: "live" })],
    readKeys: {},
    dismissedKeys: {},
    archived: [],
  });
  assert.equal(merged.length, 1);
});

test("merge carries synthetic archive rows, capped newest-first", () => {
  const archived = [];
  for (let i = 0; i < 5; i++)
    archived.push(row({ originalId: -(i + 1), timestamp: 1000 + i }));
  const merged = CenterState.mergeEntries(
    { diskRows: [], liveRows: [], readKeys: {}, dismissedKeys: {}, archived },
    { archiveCap: 3 },
  );
  assert.equal(merged.length, 3);
  assert.ok(merged.every((e) => e.unread));
});

test("withKeysAdded bounds state without resurrecting tombstoned disk rows", () => {
  let keys = {};
  keys = CenterState.withKeysAdded(keys, ["a", "b", "c"], 2);
  assert.equal(Object.keys(keys).length, 2);
  assert.ok(keys["b"] && keys["c"]);
  // Merging later with the bounded set only affects what is passed in;
  // callers must pass the live set at completion so a clear racing an
  // import is not undone by a stale snapshot.
  const merged = CenterState.mergeEntries({
    diskRows: [row({ originalId: 1, timestamp: 1000 })],
    liveRows: [],
    readKeys: {},
    dismissedKeys: keys,
    archived: [],
  });
  assert.equal(merged.length, 1);
});

test("boundKeys never prunes on transient absence while under cap", () => {
  const keys = { "1000-1": true, "2000-2": true };
  // Neither key observed in this snapshot (popup gone pre-archive, torn
  // read) -- both must survive.
  const out = CenterState.boundKeys(keys, {}, 500);
  assert.deepEqual(Object.keys(out).sort(), ["1000-1", "2000-2"]);
});

test("boundKeys over cap retains observed keys first", () => {
  const keys = { a: true, b: true, c: true, d: true };
  const out = CenterState.boundKeys(keys, { a: true }, 2);
  assert.ok(out.a, "observed key retained");
  assert.ok(out.d, "most-recent unobserved fills remaining cap");
  assert.equal(Object.keys(out).length, 2);
});

test("keysForOriginalId scopes to the live instance, not old generations", () => {
  const live = [row({ originalId: 5, timestamp: 9000 })];
  const keys = CenterState.keysForOriginalId(live, 5);
  assert.equal(keys.length, 1);
  assert.equal(keys[0], CenterState.keyOf(row({ originalId: 5, timestamp: 9000 })));
  assert.deepEqual(CenterState.keysForOriginalId(live, 6), []);
});
