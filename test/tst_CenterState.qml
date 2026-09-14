import QtQuick 2.0
import QtTest 1.0
import "../CenterState.js" as CenterState

// Isolated smoke for the pure merge logic as loaded by the QML engine.
// No Quickshell imports: runs under qmltestrunner headless.
TestCase {
  name: "CenterState"

  function test_key_identity() {
    var a = { originalId: 1, timestamp: 1000 }
    var b = { originalId: 1, timestamp: 2000 }
    verify(CenterState.keyOf(a) !== CenterState.keyOf(b))
    compare(CenterState.keyOf(a), CenterState.keyOf({ id: 99, originalId: 1, timestamp: 1000 }))
  }

  function test_malformed_line_isolated() {
    var raw = '{"originalId":1,"timestamp":1000}\n{torn\n{"originalId":2,"timestamp":2000}\n'
    var out = CenterState.parseConcatenatedLines(raw, 1)
    compare(out.length, 2)
  }

  function test_tombstone_holds() {
    var disk = [{ originalId: 5, timestamp: 5000 }]
    var key = CenterState.keyOf(disk[0])
    var dismissed = {}
    dismissed[key] = true
    var merged = CenterState.mergeEntries({
      diskRows: disk, liveRows: [], readKeys: {}, dismissedKeys: dismissed, archived: [],
    })
    compare(merged.length, 0)
  }

  function test_unread_default_and_read() {
    var disk = [{ originalId: 1, timestamp: 1000 }]
    var fresh = CenterState.mergeEntries({
      diskRows: disk, liveRows: [], readKeys: {}, dismissedKeys: {}, archived: [],
    })
    compare(fresh.length, 1)
    verify(fresh[0].unread)
    var read = {}
    read[fresh[0].key] = true
    var seen = CenterState.mergeEntries({
      diskRows: disk, liveRows: [], readKeys: read, dismissedKeys: {}, archived: [],
    })
    verify(!seen[0].unread)
  }
}
