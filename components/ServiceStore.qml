import QtQuick
import Quickshell
import Quickshell.Io
import "../CenterState.js" as CenterState

// Adapter over the first-party notification service. Old services expose
// pendingModel/pastModel and are passed through untouched. Current upstream
// keeps only popupModel with history as files under historyDir
// ("<timestamp>-<originalId>.json" each); here own fallback models are fed
// from live popup rows plus a bounded poll of that directory, since
// DND-silenced notifications never pop. Read/dismiss state is the widget's
// own notification-center.json; service disk state is never written.
Item {
  id: store

  property var service: null

  readonly property bool hasNativeHistory: !!service
    && !!service.pendingModel && !!service.pastModel
  readonly property var pendingModel: hasNativeHistory ? service.pendingModel : fbPending
  readonly property var pastModel: hasNativeHistory ? service.pastModel : fbPast
  readonly property var popupModel: service && service.popupModel ? service.popupModel : null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string historyDir: service && service.historyDir
    ? String(service.historyDir)
    : stateDir + "notifications/history/"

  readonly property int rowLimit: 200
  readonly property int keyCap: 500
  readonly property int archiveCap: 30

  ListModel { id: fbPending }
  ListModel { id: fbPast }

  signal historyChanged()

  // Own state, keyed "<timestamp>-<originalId>". Tombstones keep dismissed
  // rows gone while their file is still on disk.
  property var readKeys: ({})
  property var dismissedKeys: ({})
  property var archived: []
  property bool stateLoaded: false
  property bool dirsReady: false
  // Set on every mutation, even before the state file loads; cleared only
  // by an actual write, so a slow mkdir or a racing load cannot lose it.
  property bool dirty: false
  // Counts real model rebuilds; polls that change nothing must not bump it
  // (each rebuild resets list selection and scroll in the panel).
  property int buildCount: 0
  property string lastMergedJson: ""

  function isRead(key) { return !!readKeys[key] }

  // Mutations before the state file loads land in the live sets; loadState
  // unions the file in rather than replacing, so nothing is lost.
  function markRead(keys) {
    readKeys = CenterState.withKeysAdded(readKeys, keys, keyCap)
    saveSoon()
  }

  function dismissKeys(keys) {
    dismissedKeys = CenterState.withKeysAdded(dismissedKeys, keys, keyCap)
    if (!hasNativeHistory) rebuildFallback(liveSnapshot(), lastDiskRows)
    saveSoon()
  }

  // Withdrawals arrive with the live row's key via LiveNotifications (see
  // BarWidget's forget); the scoping helper below is what backs that key.
  // No service calls here: nothing needs releasing.

  // Scoping helper for withdrawals: keys of the live popup rows carrying
  // one notification id (ids repeat across server generations).
  function liveKeysForOriginalId(notificationId) {
    return CenterState.keysForOriginalId(liveSnapshot(), notificationId)
  }

  function popupIndexForKey(key) {
    if (!popupModel) return -1
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (row && CenterState.keyOf(row) === key) return i
    }
    return -1
  }

  function markAllRead() {
    var keys = []
    for (var i = 0; i < fbPending.count; i++) {
      var row = fbPending.get(i)
      if (row) keys.push(row.key)
    }
    markRead(keys)
    if (!hasNativeHistory) rebuildFallback(liveSnapshot(), lastDiskRows)
  }

  // Tombstones everything shown; on-screen toasts stay, matching the
  // service's own `clear`.
  function clearAll() {
    var keys = []
    var i
    for (i = 0; i < fbPending.count; i++) {
      var p = fbPending.get(i)
      if (p) keys.push(p.key)
    }
    for (i = 0; i < fbPast.count; i++) {
      var q = fbPast.get(i)
      if (q) keys.push(q.key)
    }
    dismissKeys(keys)
  }

  // Synthetic archive rows (archive IPC), negative ids never colliding.
  function archiveRow(entry) {
    var next = archived.slice()
    next.push(entry)
    next.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
    archived = next.slice(0, archiveCap)
    if (!hasNativeHistory) rebuildFallback(liveSnapshot(), lastDiskRows)
    saveSoon()
  }

  // ------------------------------------------------------------ own state

  FileView {
    id: stateFile
    path: store.stateDir + "notification-center.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: store.loadState(text())
    onLoadFailed: store.loadState("")
    onSaveFailed: function(error) {
      store.dirty = true
      console.warn("notification-center: saving state failed:", error)
    }
  }

  Timer {
    id: stateSaveTimer
    interval: 300
    repeat: false
    onTriggered: store.flushState()
  }

  Process {
    id: ensureDirsProc
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("notification-center: mkdir state dir failed:", exitCode)
        return
      }
      store.dirsReady = true
      if (store.dirty) store.saveSoon()
    }
  }

  function ensureDirs() {
    if (dirsReady || ensureDirsProc.running || hasNativeHistory) return
    ensureDirsProc.command = ["mkdir", "-p", stateDir]
    ensureDirsProc.running = true
  }

  function saveSoon() {
    dirty = true
    if (!stateLoaded) return
    if (!dirsReady) {
      ensureDirs()
      return
    }
    stateSaveTimer.restart()
  }

  function loadState(raw) {
    if (stateLoaded) return
    try {
      var parsed = JSON.parse(String(raw || "").trim() || "{}")
      var i, k
      if (Array.isArray(parsed.read)) {
        var read = {}
        for (k in readKeys) read[k] = true
        for (i = 0; i < parsed.read.length; i++) read[String(parsed.read[i])] = true
        readKeys = CenterState.boundKeys(read, {}, keyCap)
      }
      if (Array.isArray(parsed.dismissed)) {
        var dismissed = {}
        for (k in dismissedKeys) dismissed[k] = true
        for (i = 0; i < parsed.dismissed.length; i++)
          dismissed[String(parsed.dismissed[i])] = true
        dismissedKeys = CenterState.boundKeys(dismissed, {}, keyCap)
      }
      if (Array.isArray(parsed.archived)) {
        var kept = archived.slice()
        for (i = 0; i < parsed.archived.length; i++) {
          var entry = CenterState.normalizeEntry(parsed.archived[i], 1)
          if (entry) kept.push(entry)
        }
        kept.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
        archived = kept.slice(0, archiveCap)
      }
    } catch (e) {
      // Corrupt own state starts from live mutations rather than empty.
    }
    stateLoaded = true
    if (dirty) saveSoon()
    requestImport()
  }

  function flushState() {
    if (!stateLoaded || !dirsReady) return
    var out = { version: 1, read: [], dismissed: [], archived: archived.slice(0, archiveCap) }
    for (var r in readKeys) out.read.push(r)
    for (var d in dismissedKeys) out.dismissed.push(d)
    dirty = false
    stateFile.setText(JSON.stringify(out) + "\n")
  }

  // ------------------------------------------------------------- importer

  property var lastDiskRows: []
  property bool importRunning: false
  property bool importQueued: false

  Timer {
    id: importPoll
    interval: 5000
    repeat: true
    running: true
    onTriggered: store.requestImport()
  }

  // Imports run only against a present, non-native service with loaded own
  // state; requests before the service exists do nothing instead of
  // touching the native path.
  function requestImport() {
    if (!stateLoaded || !service || hasNativeHistory) return
    if (importRunning) {
      importQueued = true
      return
    }
    beginImport()
  }

  function beginImport() {
    importRunning = true
    // Per-file bound: one huge or blocking file must not starve the files
    // after it. Upstream rows are compact single-line JSON, so a newline
    // per file keeps the parse line-oriented.
    importProc.command = ["bash", "-c",
      "for f in \"$1\"/*.json; do\n" +
      "[[ -f $f ]] || continue\n" +
      "timeout 2 head -c 1048576 -- \"$f\" 2>/dev/null\n" +
      "printf '\\n'\n" +
      "done | head -c 16777216 || true",
      "--", historyDir]
    importProc.running = true
  }

  Process {
    id: importProc
    running: false
    // Drain here, never in finishImport: stdout ends before the process
    // does, and restarting a running process is a silent no-op at best.
    onExited: {
      store.importRunning = false
      if (store.importQueued) {
        store.importQueued = false
        store.requestImport()
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: store.finishImport(text)
    }
  }

  function liveSnapshot() {
    var out = []
    if (!popupModel) return out
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || Number(row.originalId) < 0) continue
      var entry = CenterState.normalizeEntry(row, 1)
      if (entry) out.push(entry)
    }
    return out
  }

  // Applies the *current* sets at completion, so a clear/read racing the
  // read wins. Absent keys are never pruned here -- only the cap bounds the
  // sets, preferring observed keys -- so a popup gone before its archive
  // lands or one torn read cannot resurrect rows. Saves only when the cap
  // actually dropped something; polls are otherwise read-only.
  function finishImport(raw) {
    if (!service || hasNativeHistory) return
    var disk = CenterState.parseConcatenatedLines(raw, 1)
    lastDiskRows = disk
    var live = liveSnapshot()
    var observed = {}
    var i
    for (i = 0; i < disk.length; i++) observed[CenterState.keyOf(disk[i])] = true
    for (i = 0; i < live.length; i++) observed[CenterState.keyOf(live[i])] = true
    for (i = 0; i < archived.length; i++) observed[CenterState.keyOf(archived[i])] = true
    var before = Object.keys(dismissedKeys).length + Object.keys(readKeys).length
    dismissedKeys = CenterState.boundKeys(dismissedKeys, observed, keyCap)
    readKeys = CenterState.boundKeys(readKeys, observed, keyCap)
    if (Object.keys(dismissedKeys).length + Object.keys(readKeys).length !== before)
      saveSoon()
    rebuildFallback(live, disk)
  }

  function rebuildFallback(live, disk) {
    var merged = CenterState.mergeEntries({
      diskRows: disk,
      liveRows: live,
      readKeys: readKeys,
      dismissedKeys: dismissedKeys,
      archived: archived,
    }, { rowLimit: rowLimit, archiveCap: archiveCap })
    // Polls that change nothing skip the models entirely: clearing and
    // re-appending resets selection and scroll in the panel every 5s.
    var json = JSON.stringify(merged)
    if (json === lastMergedJson) return
    lastMergedJson = json
    buildCount++
    fbPending.clear()
    fbPast.clear()
    for (var i = 0; i < merged.length; i++) {
      var entry = merged[i]
      var target = entry.unread ? fbPending : fbPast
      target.append({
        key: entry.key,
        id: entry.id,
        originalId: entry.originalId,
        app: entry.app,
        appIcon: entry.appIcon,
        summary: entry.summary,
        body: entry.body,
        image: entry.image,
        glyph: entry.glyph,
        execArgv: entry.execArgv,
        urgency: entry.urgency,
        expireTimeout: 0,
        timestamp: entry.timestamp,
      })
    }
    historyChanged()
  }

  Connections {
    target: store.popupModel
    function onCountChanged() { store.requestImport() }
  }

  onServiceChanged: {
    ensureDirs()
    requestImport()
  }
  onHistoryDirChanged: requestImport()

  Component.onCompleted: {
    ensureDirs()
    Qt.callLater(function() { stateFile.reload() })
  }

  Component.onDestruction: {
    if (stateSaveTimer.running) {
      stateSaveTimer.stop()
      flushState()
    }
  }
}
