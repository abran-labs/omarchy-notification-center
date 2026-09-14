import QtQuick
import Quickshell.Services.Notifications
import "../CenterState.js" as CenterState

// Watches the notification service's live objects so the center can behave
// like an inbox rather than a log of toasts.
//
// The service keeps every in-flight notification in `liveRefs`, keyed by id,
// and each of those carries the freedesktop `closed` signal plus whatever
// actions its sender registered. None of that survives into the plain rows
// the models expose, so this attaches to the objects directly and reports
// three things the rows cannot:
//
//   expired  -- the toast timed out. The service files that under "seen",
//               which is wrong when nobody was at the desk; the center uses
//               this to put it back.
//   withdrawn -- the sending app retracted the notification, which is what a
//               chat client does once the message has been read in-app. The
//               center drops it.
//   actions  -- the "default" action, which deep-links to the exact message.
//
// Everything here reads state the service already publishes, so it works on
// a stock Omarchy with no changes to the service itself.
Item {
  id: root

  // The omarchy.notifications service instance.
  property var service: null

  signal expired(int notificationId)
  signal withdrawn(int notificationId, string rowKey)

  // Ids already connected, so a notification is never wired twice. Values are
  // the objects themselves, to detect an id being reused by a new
  // notification (freedesktop replaces_id) rather than merely re-seen.
  property var watched: ({})

  // Live row key per watched id, captured when the object is first seen
  // while its popup row is still on screen. Server ids repeat across
  // generations, so a withdrawal names the exact instance retracted -- but
  // only when the lookup below found it; a popup removed first (or a toast
  // that never popped, e.g. DND-silenced) yields "" and the center must not
  // guess from the id alone.
  property var keyById: ({})

  readonly property bool available: !!service && !!service.liveRefs

  // Key of the on-screen popup row for one live id, or "" when it is not
  // (or no longer) there.
  function keyForLive(notificationId) {
    if (!service || !service.popupModel) return ""
    var id = Number(notificationId)
    for (var i = 0; i < service.popupModel.count; i++) {
      var row = service.popupModel.get(i)
      if (!row || Number(row.originalId) !== id) continue
      var entry = CenterState.normalizeEntry(row, 1)
      if (entry) return CenterState.keyOf(entry)
    }
    return ""
  }

  function refresh() {
    if (!available) return
    var refs = service.liveRefs
    // The map is rebuilt rather than mutated in place so the property change
    // is actually observed; assigning into it would mutate the same object.
    var seen = {}
    for (var key in root.watched) seen[key] = root.watched[key]

    for (var id in refs) {
      var notification = refs[id]
      if (!notification) continue
      if (seen[id] === notification) continue
      seen[id] = notification
      connect(Number(id), notification)
    }
    root.watched = seen
  }

  function connect(id, notification) {
    // Capture before wiring: the row is definitely still here now.
    var liveKey = keyForLive(id)
    var known = {}
    for (var k in root.keyById) known[k] = root.keyById[k]
    known[id] = liveKey
    root.keyById = known
    try {
      notification.closed.connect(function(reason) {
        var next = {}
        for (var key in root.watched) {
          // An id can be reused by a later notification, so only forget this
          // entry if it is still the object that just closed.
          if (Number(key) === id && root.watched[key] === notification) continue
          next[key] = root.watched[key]
        }
        root.watched = next

        var rowKey = ""
        var keys = {}
        for (var kk in root.keyById) keys[kk] = root.keyById[kk]
        if (keys[id] !== undefined && root.watched[id] === undefined) {
          rowKey = keys[id]
          delete keys[id]
        }
        root.keyById = keys

        if (reason === NotificationCloseReason.Expired) root.expired(id)
        else if (reason === NotificationCloseReason.CloseRequested) root.withdrawn(id, rowKey)
        // Dismissed means the user acted on the toast, which the service
        // already handles correctly. Nothing to add.
      })
    } catch (e) {
      // Object torn down between reading liveRefs and connecting to it.
    }
  }

  // The live object behind a row, or null once the server has released it.
  function refFor(notificationId) {
    if (!available || notificationId < 0) return null
    return service.liveRefs[notificationId] || null
  }

  function hasDefaultAction(notificationId) {
    var ref = refFor(notificationId)
    if (!ref || !ref.actions) return false
    for (var i = 0; i < ref.actions.length; i++) {
      if (ref.actions[i] && ref.actions[i].identifier === "default") return true
    }
    return false
  }

  // Fire the sender's "default" action -- "take me to this message". Returns
  // whether anything was actually invoked.
  function invokeDefault(notificationId) {
    var ref = refFor(notificationId)
    if (!ref || !ref.actions) return false
    for (var i = 0; i < ref.actions.length; i++) {
      var action = ref.actions[i]
      if (!action || action.identifier !== "default") continue
      try {
        action.invoke()
        return true
      } catch (e) {
        return false
      }
    }
    return false
  }

  // liveRefs is a plain JS object, so it emits no change signal. Polling is
  // the only way to notice new entries; the interval only affects how quickly
  // a notification is adopted, and every notification lingers far longer than
  // this.
  Timer {
    interval: 250
    repeat: true
    running: root.available
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
