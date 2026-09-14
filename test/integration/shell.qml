import QtQuick
import Quickshell
import "../../components" as C

// Integration harness for ServiceStore, run headless under quickshell:
//   HOME=<fakehome> HARNESS_HIST=<fixture history dir> \
//     HARNESS_PHASE=main|reload quickshell --path test/integration
//
// The fake service exposes popupModel + historyDir only (no pending/past),
// so the store takes its fallback path. Each step asserts, then either ends
// the run or waits for the next historyChanged before continuing.
ShellRoot {
  id: shellRoot

  property string phase: Quickshell.env("HARNESS_PHASE") || "main"
  property int step: 0
  property bool waiting: false
  property int passed: 0
  property int failed: 0
  property bool done: false
  property int c0: 0

  function check(cond, name) {
    if (cond) {
      passed++
      console.log("HARNESS-CHECK " + name + " ok")
    } else {
      failed++
      console.log("HARNESS-CHECK " + name + " FAIL")
    }
  }

  function finish() {
    if (done) return
    done = true
    console.log("HARNESS-RESULT: " + (failed === 0 ? "PASS" : "FAIL")
      + " " + passed + "/" + (passed + failed))
  }

  ListModel {
    id: fakePopup
    Component.onCompleted: {
      if (shellRoot.phase !== "main") return
      append({
        id: 5, originalId: 5, app: "chat", appIcon: "", summary: "live",
        body: "b", image: "", glyph: "", execArgv: "", urgency: 1,
        expireTimeout: 0, timestamp: 9000,
      })
    }
  }

  Item {
    id: fakeService
    property var popupModel: fakePopup
    property string historyDir: Quickshell.env("HARNESS_HIST") || ""
  }

  ListModel {
    id: nativePending
    Component.onCompleted: {
      if (shellRoot.phase !== "native") return
      append({
        key: "9000-5", id: 5, originalId: 5, app: "chat", appIcon: "",
        summary: "n", body: "", image: "", glyph: "", execArgv: "",
        urgency: 1, expireTimeout: 0, timestamp: 9000,
      })
    }
  }

  ListModel { id: nativePast }

  Item {
    id: nativeService
    property var pendingModel: nativePending
    property var pastModel: nativePast
  }

  C.ServiceStore {
    id: store
    service: shellRoot.phase === "native" ? nativeService : fakeService
    onHistoryChanged: {
      if (waiting && !done) {
        waiting = false
        importSettle.stop()
        advance()
      }
    }
  }

  function keysOf(model) {
    var out = []
    for (var i = 0; i < model.count; i++) {
      var row = model.get(i)
      if (row) out.push(row.key)
    }
    return out
  }

  function allKeys() {
    return keysOf(store.pendingModel).concat(keysOf(store.pastModel))
  }

  function hasKey(key) { return allKeys().indexOf(key) !== -1 }

  function expectImport() {
    waiting = true
    store.requestImport()
    // Unchanged imports stay silent by design (no model rebuild), so a
    // settle timer advances the run when there is nothing to report.
    importSettle.restart()
  }

  Timer {
    id: importSettle
    interval: 2500
    repeat: false
    onTriggered: {
      if (shellRoot.waiting && !shellRoot.done) {
        shellRoot.waiting = false
        advance()
      }
    }
  }

  function advance() {
    step++
    if (phase === "reload") {
      check(store.pendingModel.count === 0 && store.pastModel.count === 0,
        "reload-tombstones-survive-restart")
      finish()
      return
    }    if (step === 1) {
      // Fixture: 9000-5 (also live), 8000-7 (disk-only, DND-silenced),
      // 1000-5 (old generation, same id), plus a torn file.
      check(hasKey("9000-5"), "live-plus-disk-merged")
      check(hasKey("8000-7"), "silenced-disk-row-surfaces")
      check(hasKey("1000-5"), "old-generation-row-surfaces")
      check(allKeys().length === 3, "torn-file-isolated")
      store.dismissKeys(["8000-7"])
      check(!hasKey("8000-7"), "dismiss-hides-row")
      expectImport()
    } else if (step === 2) {
      // Tombstone holds across a reimport with the file still on disk.
      check(!hasKey("8000-7"), "tombstone-holds-across-reimport")
      store.markAllRead()
      check(store.pendingModel.count === 0 && store.pastModel.count === 2,
        "mark-all-read-moves-buckets")
      expectImport()
    } else if (step === 3) {
      // Read marks survive a poll that transiently misses nothing here,
      // and withdrawal scopes to the live instance's key.
      check(store.pendingModel.count === 0, "read-marks-hold-across-poll")
      // Same scoping the live withdrawal signal path uses: the live
      // instance's key only, never the old generation sharing its id.
      var liveKeys = store.liveKeysForOriginalId(5)
      check(liveKeys.length === 1 && liveKeys[0] === "9000-5",
        "withdraw-scoped-to-live-key")
      store.dismissKeys(liveKeys)
      check(!hasKey("9000-5"), "withdraw-drops-live-instance")
      check(hasKey("1000-5"), "withdraw-spares-old-generation")
      store.archiveRow({
        id: -1, originalId: -1, app: "self", appIcon: "", summary: "syn",
        body: "", image: "", glyph: "", execArgv: "", urgency: 1,
        expireTimeout: 0, timestamp: 9500,
      })
      check(hasKey("9500--1"), "synthetic-archive-row-surfaces")
      store.clearAll()
      check(allKeys().length === 0, "clear-empties-list")
      expectImport()
    } else if (step === 4) {
      // Everything tombstoned stays gone although every file is on disk.
      check(allKeys().length === 0, "clear-tombstones-hold-across-reimport")
      // An import that changes nothing must not rebuild the models (each
      // rebuild resets selection and scroll in the panel).
      c0 = store.buildCount
      store.requestImport()
      settle.restart()
    }
  }

  Timer {
    id: settle
    interval: 2500
    repeat: false
    onTriggered: {
      if (shellRoot.done) return
      check(store.buildCount === shellRoot.c0, "no-rebuild-on-unchanged-poll")
      finish()
    }
  }

  Timer {
    id: nativeSettle
    interval: 2000
    repeat: false
    onTriggered: {
      if (shellRoot.done) return
      check(store.hasNativeHistory, "native-detected")
      check(store.pendingModel === nativeService.pendingModel, "native-pending-passthrough")
      check(store.pastModel === nativeService.pastModel, "native-past-passthrough")
      check(store.lastDiskRows.length === 0 && store.buildCount === 0,
        "native-no-fallback-import")
      finish()
    }
  }

  Timer {
    interval: 25000
    repeat: false
    running: !done
    onTriggered: {
      console.log("HARNESS-CHECK watchdog-timeout FAIL")
      failed++
      finish()
    }
  }

  Component.onCompleted: {
    // Native phase never emits historyChanged (no fallback import runs),
    // so it is driven by a settle timer instead.
    if (phase === "native") nativeSettle.restart()
    else waiting = true
  }
}
