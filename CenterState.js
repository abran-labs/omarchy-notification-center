// Own read/dismiss state + merge logic for the notification center.
//
// The upstream (quattro) notification service keeps only `popupModel`.
// Everything a toast leaves behind lives on disk under
// ~/.local/state/omarchy/notifications/history/ -- one compact JSON row per
// file, named "<timestamp>-<originalId>.json". DND-silenced notifications
// never pop, so they only ever exist there. This module is the pure,
// testable half of that compatibility: identity, normalization, and the
// merge of disk rows + live popup rows + the widget's own read/dismiss
// state into the flat list the panel renders.
//
// Identity is timestamp+originalId. Server ids restart from 1 with every
// server process, so an id alone collides across generations; the timestamp
// travels with the row through every round-trip and disambiguates.
//
// Nothing here touches the service or the disk. The QML side (ServiceStore)
// reads state at import completion and passes the *current* read/dismiss
// sets in, so a clear/read/archive racing an import is applied rather than
// overwritten by a stale snapshot.
//
// Pure ES5-style JS so it loads both in QML (`import "CenterState.js" as
// CenterState`) and in node:test.
function keyOf(entry) {
  var e = entry || {};
  return String(e.timestamp || 0) + "-" + String(e.originalId || 0);
}

// Normalize one parsed disk/live row into the shape the panel consumes.
// Returns null for rows without a usable identity.
function normalizeEntry(raw, normalUrgency) {
  var e = raw || {};
  if (typeof e !== "object") return null;
  var originalId = Number(e.originalId === undefined ? e.id : e.originalId);
  var timestamp = Number(e.timestamp || 0);
  if (!isFinite(originalId) || !isFinite(timestamp) || timestamp <= 0) return null;
  var urgency = Number(e.urgency === undefined ? normalUrgency : e.urgency);
  if (!isFinite(urgency)) urgency = Number(normalUrgency) || 1;
  return {
    id: Number(e.id === undefined ? originalId : e.id) || 0,
    originalId: originalId,
    app: String(e.app || ""),
    appIcon: String(e.appIcon || ""),
    summary: String(e.summary || ""),
    body: String(e.body || ""),
    image: String(e.image || ""),
    glyph: String(e.glyph || ""),
    execArgv: String(e.execArgv || ""),
    urgency: urgency,
    expireTimeout: 0,
    timestamp: timestamp,
  };
}

// Parse the concatenation of every history file (`awk 1 dir/*.json`).
// One torn write must not take down the rest: malformed lines are skipped.
function parseConcatenatedLines(raw, normalUrgency) {
  var lines = String(raw || "").split("\n");
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    try {
      var value = JSON.parse(line);
      var entry = normalizeEntry(value, normalUrgency);
      if (entry) out.push(entry);
    } catch (e) {
      // Torn write from a crash mid-save -- skip the line, keep the rest.
    }
  }
  return out;
}

// Merge disk rows, live popup rows, and own state into panel rows,
// newest-first. Disk and live copies of one key collapse to one row;
// tombstoned (dismissed/cleared) keys stay out even while their file is
// still on disk; everything not marked read is unread.
function mergeEntries(args, opts) {
  var o = opts || {};
  var rowLimit = Number(o.rowLimit === undefined ? 200 : o.rowLimit);
  if (!isFinite(rowLimit) || rowLimit < 0) rowLimit = 200;
  var archiveCap = Number(o.archiveCap === undefined ? 30 : o.archiveCap);
  if (!isFinite(archiveCap) || archiveCap < 0) archiveCap = 30;

  var a = args || {};
  var readKeys = a.readKeys || {};
  var dismissedKeys = a.dismissedKeys || {};
  var seen = {};
  var out = [];

  function consider(raw) {
    var entry = normalizeEntry(raw, a.normalUrgency === undefined ? 1 : a.normalUrgency);
    if (!entry) return;
    var key = keyOf(entry);
    if (seen[key] || dismissedKeys[key]) return;
    seen[key] = true;
    entry.key = key;
    entry.unread = !readKeys[key];
    out.push(entry);
  }

  var diskRows = Array.isArray(a.diskRows) ? a.diskRows : [];
  var liveRows = Array.isArray(a.liveRows) ? a.liveRows : [];
  var i;
  for (i = 0; i < diskRows.length; i++) consider(diskRows[i]);
  for (i = 0; i < liveRows.length; i++) consider(liveRows[i]);

  var archived = Array.isArray(a.archived) ? a.archived.slice() : [];
  archived.sort(function(x, y) { return (y.timestamp || 0) - (x.timestamp || 0); });
  var kept = 0;
  for (i = 0; i < archived.length && kept < archiveCap; i++) {
    var before = out.length;
    consider(archived[i]);
    if (out.length > before) kept++;
  }

  out.sort(function(x, y) {
    var dt = (y.timestamp || 0) - (x.timestamp || 0);
    if (dt !== 0) return dt;
    return (y.originalId || 0) - (x.originalId || 0);
  });
  return out.slice(0, rowLimit);
}

// Return a copy of a key set with keys added, bounded to max entries.
// Oldest-inserted keys drop first; insertion order is what `for in`
// preserves for string keys.
function withKeysAdded(keys, additions, max) {
  var next = {};
  for (var k in keys) next[k] = true;
  for (var i = 0; i < additions.length; i++) next[additions[i]] = true;
  return boundKeys(next, {}, max);
}

// Bound a key set to max entries without ever dropping a key merely for
// being absent from one snapshot: a live popup gone before its archive
// lands, or one torn read, must not clear dismissal/read marks and resurrect
// rows on the next poll. Observed keys are always retained first; beyond
// them the most recently added unobserved keys survive.
function boundKeys(keys, observed, max) {
  var names = Object.keys(keys || {});
  if (names.length <= max) {
    var kept = {};
    for (var i = 0; i < names.length; i++) kept[names[i]] = true;
    return kept;
  }
  var out = {};
  var count = 0;
  var j, k;
  for (j = 0; j < names.length; j++) {
    k = names[j];
    if (observed && observed[k]) {
      out[k] = true;
      count++;
    }
  }
  for (j = names.length - 1; j >= 0 && count < max; j--) {
    k = names[j];
    if (!out[k]) {
      out[k] = true;
      count++;
    }
  }
  return out;
}

// Keys of rows carrying one notification id. A withdrawal names only the
// id, but ids repeat across server generations -- callers pass the live
// popup rows so the tombstone scopes to the instance actually retracted,
// never to an old-generation row sharing its id.
function keysForOriginalId(rows, originalId) {
  var out = [];
  var id = Number(originalId);
  for (var i = 0; i < (rows || []).length; i++) {
    var entry = normalizeEntry(rows[i], 1);
    if (entry && entry.originalId === id) out.push(keyOf(entry));
  }
  return out;
}

if (typeof module !== "undefined") {
  module.exports = {
    keyOf: keyOf,
    normalizeEntry: normalizeEntry,
    parseConcatenatedLines: parseConcatenatedLines,
    mergeEntries: mergeEntries,
    withKeysAdded: withKeysAdded,
    boundKeys: boundKeys,
    keysForOriginalId: keysForOriginalId,
  };
}
