// Notification center: a bell with an unread badge, and a panel listing
// unread notifications above already-seen ones.
//
// Data comes entirely from Omarchy's first-party notification service. That
// service already keeps the two buckets this UI needs -- `pendingModel`
// (arrived, not yet seen by the user) and `pastModel` (seen) -- and persists
// both to disk, so there is no second daemon, no polling, and no separate
// history file here. Unread/read is the service's own notion of seen, which
// means opening the panel marks things read exactly the way the toasts do.
//
// UI conventions follow the first-party panels (audio, bluetooth, network):
// KeyboardPanel, a hero header, CursorSurface rows whose highlight is driven
// by panel cursor state rather than raw hover, and no explanatory chrome --
// no panel title bar, no close button, no keybinding legend.
import QtQuick
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "components"
import "BodyText.js" as BodyText
import "Sources.js" as Sources
import "Rules.js" as Rules

BarWidget {
  id: root
  moduleName: "shavanced.notification-center"

  // ---------------------------------------------------------------- service

  readonly property var hostShell: bar && bar.shell ? bar.shell : null
  readonly property var service: hostShell && hostShell.firstPartyServiceFor
    ? hostShell.firstPartyServiceFor("omarchy.notifications") : null

  readonly property var pendingModel: service ? service.pendingModel : null
  readonly property var pastModel: service ? service.pastModel : null

  // Counted from the rows this widget actually shows, not from the service's
  // models, so a hidden sender does not keep the badge lit for a
  // notification the user has said they never want to see.
  readonly property int unreadCount: countRows(true)
  readonly property int seenCount: countRows(false)
  readonly property int totalCount: rows.length

  function countRows(unread) {
    var n = 0
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].unread === unread) n++
    }
    return n
  }

  readonly property bool dndSupported: !!service
    && typeof service.doNotDisturb === "boolean"
    && typeof service.setDoNotDisturb === "function"
  readonly property bool dnd: dndSupported && service.doNotDisturb

  // Per-app rules are owned here rather than by the service, so they work on
  // a stock Omarchy install. Both are lists of lowercase substrings matched
  // against a notification's app_name.
  //
  //   hidden  -- kept out of this list entirely. The sender still notifies;
  //              its toast still pops. It just isn't filed here.
  //   exempt  -- asks the service to keep showing this sender's toasts while
  //              notifications are silenced. Needs service support, so it is
  //              capability-gated below.
  // `settings` is assigned by the bar after this component is constructed,
  // so this has to re-read on every change rather than being evaluated once.
  property var hiddenApps: []
  property var exemptApps: []

  onSettingsChanged: root.loadRules()

  function loadRules() {
    root.hiddenApps = Rules.list(setting("hiddenApps", []))
    rebuild()
  }

  function isHidden(app) { return Rules.matches(root.hiddenApps, app) }
  function isExempt(app) { return Rules.matches(root.exemptApps, app) }

  // Rules persist onto this widget's own shell.json entry.
  function saveRule(key, value) {
    if (!hostShell || typeof hostShell.updateEntryInline !== "function") return
    var patch = {}
    patch[key] = value
    hostShell.updateEntryInline(root.moduleName, patch)
  }

  // Capability probe. Letting a sender through while notifications are
  // silenced is the one rule the service has to enforce, because the service
  // is what decides whether a toast is shown at all. Detected rather than
  // assumed, and its controls hide when unavailable.
  readonly property bool canExemptApps: !!service
    && typeof service.allowThroughDnd === "function"
    && typeof service.denyThroughDnd === "function"
    && typeof service.isDndAllowed === "function"

  // ---------------------------------------------------------------- live
  //
  // Behaviour that needs the in-flight notification objects rather than the
  // plain rows: not treating a timed-out toast as read, dropping a
  // notification the sender withdrew, and deep-linking into the message.
  LiveNotifications {
    id: live
    service: root.service

    // A toast that expired proves nothing about whether it was seen -- the
    // common case for a notification center is that nobody was at the desk.
    // The service files it under "seen" anyway, so move it back.
    onExpired: function(notificationId) { root.restoreUnread(notificationId) }

    // The sending app retracted it, which is what a chat client does once
    // the message has been read in-app. Drop it.
    onWithdrawn: function(notificationId) { root.forget(notificationId) }
  }

  readonly property bool canDeepLink: live.available

  // Ids waiting to be moved back out of the "seen" bucket.
  //
  // The service files an expired toast as seen from inside its own
  // Qt.callLater, so at the moment `closed` fires the row is still pending
  // and there is nothing to move yet. Queuing a single callLater behind it
  // is not enough either -- the two are not ordered. So the id is recorded
  // and a short-lived timer watches for it to actually land in past.
  property var restoreQueue: ({})

  function restoreUnread(notificationId) {
    var queue = root.restoreQueue
    queue[notificationId] = 0
    root.restoreQueue = queue
    restoreTimer.running = true
  }

  Timer {
    id: restoreTimer
    interval: 60
    repeat: true
    running: false

    onTriggered: {
      if (!root.pastModel || !root.pendingModel) { running = false; return }

      var queue = root.restoreQueue
      var pending = false
      var changed = false

      for (var key in queue) {
        var id = Number(key)
        var moved = false

        for (var i = 0; i < root.pastModel.count; i++) {
          var row = root.pastModel.get(i)
          if (!row || row.originalId !== id) continue
          var snapshot = root.snapshotOf(row)
          root.pastModel.remove(i)
          root.pendingModel.insert(0, snapshot)
          moved = true
          changed = true
          break
        }

        if (moved) {
          delete queue[key]
          continue
        }

        // Give the service a few ticks to file it. If it never shows up the
        // notification was dismissed rather than archived, and there is
        // nothing to restore.
        queue[key] += 1
        if (queue[key] > 12) delete queue[key]
        else pending = true
      }

      root.restoreQueue = queue
      if (changed) {
        root.persistModels()
        root.rebuild()
      }
      if (!pending) running = false
    }
  }

  function forget(notificationId) {
    if (!pendingModel || !pastModel) return
    var models = [pendingModel, pastModel]
    var removed = false
    for (var m = 0; m < models.length; m++) {
      var model = models[m]
      for (var i = model.count - 1; i >= 0; i--) {
        var row = model.get(i)
        if (!row || row.originalId !== notificationId) continue
        model.remove(i)
        removed = true
      }
    }
    if (removed) {
      persistModels()
      rebuild()
    }
  }

  // The service writes its history file on its own edits, so a change made
  // directly to the models has to ask for the write -- otherwise it is
  // correct on screen and wrong again after a restart.
  function persistModels() {
    if (service && typeof service.scheduleHistorySave === "function")
      service.scheduleHistorySave()
  }

  // Copy a ListModel row into a plain object so it can be reinserted into a
  // different model without carrying a reference to the original.
  function snapshotOf(row) {
    return {
      id: row.id,
      originalId: row.originalId,
      app: row.app,
      appIcon: row.appIcon,
      summary: row.summary,
      body: row.body,
      image: row.image,
      glyph: row.glyph || "",
      urgency: row.urgency,
      expireTimeout: row.expireTimeout || 0,
      timestamp: row.timestamp
    }
  }

  function toggleDnd() {
    if (dndSupported) service.setDoNotDisturb(!service.doNotDisturb)
  }

  // ------------------------------------------------------------- panel state

  property bool opened: false
  property var rows: []

  // Panel cursor, mirroring the first-party panels: mouse hover and keyboard
  // navigation both write here, and rows derive their highlight from it, so
  // only one row is ever lit. `headerFocused` is the header's slot in the
  // same cursor -- it has to be an explicit state rather than "no row is
  // selected", or the header would sit lit whenever the panel is at rest.
  property int selectedIndex: -1
  property bool cursorActive: false
  property bool headerFocused: false

  // True when the cursor was last moved by the keyboard. Only then may the
  // list scroll itself to follow the cursor -- a pointer is already where
  // the user put it.
  property bool keyboardCursor: false

  // Width taken out of the list for the scrollbar, so rows end beside the
  // handle instead of running under it. Zero when nothing overflows and no
  // bar is drawn.
  readonly property real listGutter: listScrollable ? Style.space(9) : 0
  property bool listScrollable: false

  // Row-level context menu. Anchored to the row it was opened on, so it
  // closes with the panel and never outlives its subject.
  property var menuRow: null
  property real menuX: 0
  property real menuY: 0
  readonly property bool menuOpen: menuRow !== null

  function openRowMenu(row, x, y) {
    root.menuRow = row
    root.menuX = x
    root.menuY = y
  }

  function closeRowMenu() {
    root.menuRow = null
  }

  // Hide a sender from this list. Rules are keyed on the sender's own
  // app_name, not the pretty source label -- the label is this widget's
  // invention and would not match anything on the next notification.
  function muteSource(row) {
    if (!row) return
    root.saveRule("hiddenApps", Rules.add(root.hiddenApps, row.app))
    root.closeRowMenu()
    rebuild()
  }

  function unmuteSource(app) {
    root.saveRule("hiddenApps", Rules.remove(root.hiddenApps, app))
    rebuild()
  }

  // Senders allowed to keep popping toasts while notifications are silenced.
  // The service owns this one, because the service is what suppresses toasts.
  readonly property var alwaysShowApps: root.exemptApps

  function isAlwaysShown(app) {
    if (!root.canExemptApps) return false
    return service.isDndAllowed(app)
  }

  function toggleAlwaysShow(row) {
    if (!root.canExemptApps || !row) return
    if (root.isAlwaysShown(row.app)) service.denyThroughDnd(row.app)
    else service.allowThroughDnd(row.app)
    root.syncExemptApps()
    root.closeRowMenu()
  }

  function allowSource(app) {
    if (!root.canExemptApps) return
    service.denyThroughDnd(app)
    root.syncExemptApps()
  }

  function syncExemptApps() {
    root.exemptApps = root.canExemptApps && service.dndAllowlist
      ? service.dndAllowlist : []
  }

  // ------------------------------------------------------- manage popup
  //
  // Right-clicking the bell opens this rather than blind-toggling DND: the
  // "never show again" choices made from row menus are otherwise invisible
  // and irreversible from the UI.
  property bool managePopupOpen: false

  readonly property var mutedApps: root.hiddenApps

  function toggleManagePopup() {
    root.managePopupOpen = !root.managePopupOpen
  }

  // What to call a sender in the UI: its source label if we have one, its
  // own app name otherwise.
  function displayName(row) {
    if (!row) return ""
    var source = root.sourceFor(row.app)
    return source ? source.label : row.app
  }

  function focusHeader() {
    root.cursorActive = true
    root.headerFocused = true
    root.selectedIndex = -1
  }

  function blurHeader() {
    root.headerFocused = false
    root.cursorActive = false
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color faint: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)

  readonly property string barIcon: {
    if (dnd) return "󰂛"
    if (unreadCount > 0) return "󱅫"
    return "󰂚"
  }

  // Unread is the only number worth showing on a bar icon; a total count of
  // things already read is noise.
  readonly property string badgeText: unreadCount > 99 ? "99+" : String(unreadCount)

  function open() {
    root.opened = true
    rebuild()
    // A ListView keeps its scroll offset between showings, so reopening the
    // panel could start part-way down the list with the newest rows -- and
    // the UNREAD header above them -- already scrolled off the top.
    Qt.callLater(function() {
      if (list) list.positionViewAtBeginning()
    })
  }

  function close() {
    root.opened = false
    root.cursorActive = false
    root.selectedIndex = -1
    root.closeRowMenu()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // --------------------------------------------------------------- row model
  //
  // One flat list, unread first, each bucket newest-first. A flat list keeps
  // keyboard navigation and index math trivial; the section header is drawn
  // by the delegate when the bucket changes.

  // Sender-controlled strings are clamped before they enter the widget's own
  // copy of the row. The service caps how many rows it keeps but not how long
  // each field is, so a local sender could otherwise park megabytes in the
  // body of a single notification -- and it persists into history, where the
  // widget would reload and reprocess it on every rebuild. Limits are far
  // above anything a real message needs and are applied only to the widget's
  // display copy; the service's own models are left alone.
  readonly property int fieldLimit: 2048
  readonly property int rowLimit: 200

  function clamp(text) {
    var value = String(text || "")
    return value.length > fieldLimit ? value.slice(0, fieldLimit) : value
  }

  function rowsFrom(model, unread) {
    var out = []
    if (!model) return out
    for (var i = 0; i < model.count && out.length < rowLimit; i++) {
      var entry = model.get(i)
      if (!entry) continue
      // Hidden senders are filtered on the way out rather than being dropped
      // from the service's models: the service is shared, and its history is
      // not this widget's to edit. Unhiding a sender brings its existing
      // notifications straight back.
      if (root.isHidden(entry.app)) continue
      out.push({
        unread: unread,
        index: i,
        // Handle back to the live notification, for deep-linking.
        originalId: entry.originalId === undefined ? -1 : Number(entry.originalId),
        app: clamp(entry.app || "Unknown app"),
        appIcon: clamp(entry.appIcon),
        summary: clamp(entry.summary),
        body: clamp(entry.body),
        image: clamp(entry.image),
        glyph: clamp(entry.glyph),
        urgency: Number(entry.urgency === undefined ? 1 : entry.urgency),
        timestamp: Number(entry.timestamp || 0)
      })
    }
    return out
  }

  function rebuild() {
    var next = rowsFrom(pendingModel, true).concat(rowsFrom(pastModel, false))
    root.rows = next
    if (root.selectedIndex >= next.length) root.selectedIndex = next.length - 1
  }

  // Dismissing shifts every later index in the same bucket, so rows carry
  // their bucket + index and we dispatch on that rather than caching handles.
  function dismiss(row, activate) {
    if (!service || !row) return
    // Fire the sender's deep-link before dropping the row: dismissing
    // releases the notification, and with it the action.
    if (activate === true) live.invokeDefault(row.originalId)
    if (row.unread) service.dismissPending(row.index)
    else service.dismissPast(row.index)
    rebuild()
  }

  // Jump to whatever sent the notification, then drop it -- acting on a
  // message is the same as having read it.
  //
  // Two separate jobs, and both have to happen:
  //
  //  1. Navigate. The notification's own "default" action tells the client
  //     to open that exact channel or DM. The service invokes it while
  //     releasing the notification.
  //  2. Raise. Invoking the action only navigates *within* the app -- it
  //     does not bring the window forward, and for an app sitting in the
  //     tray there may be no window at all. Doing only step 1 left the app
  //     on the right channel but still hidden.
  //
  // So the raise always runs. launch-or-focus rather than plain focus,
  // because focusing by class finds nothing when the app is in the tray.
  function activateRow(row) {
    if (!row) return

    var source = root.sourceFor(row.app)
    var pattern = source ? source.focusClass : row.app
    if (pattern) {
      var command = omarchyPath + "/bin/omarchy-launch-or-focus "
        + shellQuote(String(pattern))
      if (source && source.launch) command += " " + shellQuote(source.launch)
      root.run(command)
    }

    root.dismiss(row, true)
    root.close()
  }

  function rowCanDeepLink(row) {
    if (!row || row.originalId === undefined) return false
    return live.hasDefaultAction(row.originalId)
  }

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function run(command) {
    if (bar && typeof bar.run === "function") bar.run(command)
  }

  function clearAll() {
    if (!service) return
    service.clearPending()
    service.clearPast()
    rebuild()
  }

  function markAllRead() {
    if (!service) return
    service.markAllSeen()
    rebuild()
  }

  function activate() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.rows.length) return
    root.dismiss(root.rows[root.selectedIndex])
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    root.cursorActive = true
    root.headerFocused = false
    root.keyboardCursor = true
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next > root.rows.length - 1) next = root.rows.length - 1
    root.selectedIndex = next
  }

  function setCursor(index) {
    root.cursorActive = true
    root.headerFocused = false
    root.keyboardCursor = false
    root.selectedIndex = index
  }

  function clearCursor(index) {
    if (root.selectedIndex === index) root.cursorActive = false
  }

  // Relative time reads faster than a clock when scanning a feed: "3m" answers
  // "is this still relevant" without the reader doing arithmetic.
  function relativeTime(ms) {
    var then = Number(ms) || 0
    if (then <= 0) return ""
    var delta = Math.max(0, Date.now() - then)
    var mins = Math.floor(delta / 60000)
    if (mins < 1) return "now"
    if (mins < 60) return mins + "m"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + "h"
    var days = Math.floor(hours / 24)
    if (days < 7) return days + "d"
    return new Date(then).toLocaleDateString(Qt.locale(), "MMM d")
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    return Quickshell.iconPath(value, true)
  }

  // -------------------------------------------------------------- sources
  //
  // Known senders, with a label, tint, fallback glyph, and the window to
  // raise when one of their rows is clicked. Unknown senders still appear,
  // rendered with their own app name and the neutral foreground.
  //
  // Built-ins live in Sources.js; the `sources` setting on this widget's
  // shell.json entry adds to them, overrides one by `key`, or removes one
  // with `"enabled": false`.
  readonly property var sources: Sources.resolve(setting("sources", []))

  function sourceFor(app) {
    return Sources.forApp(root.sources, app)
  }

  Connections {
    target: root.pendingModel
    function onCountChanged() { root.rebuild() }
  }

  Connections {
    target: root.pastModel
    function onCountChanged() { root.rebuild() }
  }

  // Only while open, and only to re-render "3m" -> "4m".
  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.rebuild()
  }

  Component.onCompleted: {
    loadRules()
    syncExemptApps()
  }

  // Lets the panel be bound to a key without going through the bar icon:
  //   omarchy-shell notification-center toggle
  //
  // Editing this widget's settings drops the IPC target until the shell
  // restarts: the bar builds the replacement widget before destroying the
  // outgoing one, so two handlers briefly claim the same name and the
  // newcomer is refused. That affects Omarchy's own widgets identically
  // (SystemUpdate.qml logs the same warning), so it is left alone here
  // rather than worked around with a timer that only narrows the race.
  // Settings changes are rare; the bar icon never depends on this.
  IpcHandler {
    target: "notification-center"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function markAllRead(): void { root.markAllRead() }
    function clear(): void { root.clearAll() }
    function unread(): string { return String(root.unreadCount) }
  }

  // ------------------------------------------------------------------ bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    active: root.unreadCount > 0 && !root.dnd
    // The panel is the detail view, so the icon carries no tooltip.
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleManagePopup()
      else root.toggle()
    }

    // Count badge, top-right per convention, unread only.
    Rectangle {
      visible: root.unreadCount > 0 && !root.dnd
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(1)
      anchors.topMargin: Style.space(2)
      width: Math.max(height, badgeLabel.implicitWidth + Style.space(4))
      height: Style.space(11)
      radius: height / 2
      color: Color.accent

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        text: root.badgeText
        color: Color.background
        font.family: root.fontFamily
        font.pixelSize: Math.max(8, Style.font.caption - 2)
        font.bold: true
      }
    }
  }

  // -------------------------------------------------------- manage popup

  PopupCard {
    id: managePopup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.managePopupOpen
    contentWidth: managePopup.fittedContentWidth(Style.space(300))
    contentHeight: managePopup.fittedContentHeight(manageColumn.implicitHeight)

    function close() { root.managePopupOpen = false }

    Column {
      id: manageColumn
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        text: "Notifications"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      // DND lives here now that right-click opens this popup instead of
      // toggling it blind.
      Item {
        width: parent.width
        implicitHeight: Style.space(28)
        visible: root.dndSupported

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Silence notifications"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        ToggleSwitch {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.dnd
          foreground: root.foreground
          onToggled: root.toggleDnd()
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      Text {
        text: "Never shown"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        visible: root.mutedApps.length === 0
        text: "Nothing is silenced."
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      Repeater {
        model: root.mutedApps

        delegate: Item {
          id: mutedRow
          required property var modelData
          width: manageColumn.width
          implicitHeight: Style.space(28)

          readonly property string label: {
            var source = root.sourceFor(mutedRow.modelData)
            return source ? source.label : String(mutedRow.modelData)
          }

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: showBtn.left
            anchors.rightMargin: Style.space(8)
            text: mutedRow.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Button {
            id: showBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf06e"
            text: "Show"
            foreground: root.foreground
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            iconSize: Style.font.bodySmall
            fontSize: Style.font.bodySmall
            onClicked: root.unmuteSource(mutedRow.modelData)
          }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
        visible: root.alwaysShowApps.length > 0
      }

      Text {
        visible: root.alwaysShowApps.length > 0
        text: "Always shown"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Repeater {
        model: root.alwaysShowApps

        delegate: Item {
          id: allowedRow
          required property var modelData
          width: manageColumn.width
          implicitHeight: Style.space(28)

          readonly property string label: {
            var source = root.sourceFor(allowedRow.modelData)
            return source ? source.label : String(allowedRow.modelData)
          }

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: stopBtn.left
            anchors.rightMargin: Style.space(8)
            text: allowedRow.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Button {
            id: stopBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf1f6"
            text: "Silence"
            foreground: root.foreground
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            iconSize: Style.font.bodySmall
            fontSize: Style.font.bodySmall
            onClicked: root.allowSource(allowedRow.modelData)
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Height follows the content, so a short list gets a short card instead
    // of a tall one padded with dead space.
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(560))
    focusTarget: keyCatcher

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activate()
      onReturnRequested: root.activate()
      onDeleteRequested: root.activate()
      // Esc backs out of the menu first, then out of the panel.
      onCloseRequested: {
        if (root.menuOpen) root.closeRowMenu()
        else root.close()
      }
    }

    // Wrapper so the context menu can be positioned against the panel's
    // whole content area rather than inside the scrolling list.
    Item {
      id: panelBody
      anchors.fill: parent

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(14)

      // ----------------------------------------------------------- hero
      //
      // Icon, name, and the one status line that matters (how many unread),
      // with DND as the trailing switch. No panel title bar, no close button.
      Item {
        id: header
        width: parent.width
        implicitHeight: hero.implicitHeight

        readonly property bool ringVisible: root.cursorActive && root.headerFocused

        PanelHero {
          id: hero
          width: parent.width
          title: "Notifications"
          meta: {
            if (root.unreadCount > 0) {
              var count = root.unreadCount + " unread"
              return root.dnd ? count + " · silenced" : count
            }
            if (root.dnd) return "Silenced"
            if (root.totalCount > 0) return "All caught up"
            return "No notifications"
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.dnd ? 0.5 : 1.0

          iconComponent: Component {
            Text {
              text: root.barIcon
              color: root.unreadCount > 0 && !root.dnd ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            ToggleSwitch {
              id: dndSwitch
              visible: root.dndSupported
              checked: root.dnd
              hasCursor: header.ringVisible
              foreground: root.foreground
              onHovered: function(on) { if (on) root.focusHeader(); else root.blurHeader() }
              onToggled: root.toggleDnd()

              PanelToolTip {
                visible: dndSwitch.containsMouse
                text: root.dnd ? "Allow notifications" : "Silence notifications"
                fontFamily: root.fontFamily
              }
            }
          }
        }
      }

      // ---------------------------------------------------------- list
      //
      // The list and its scrollbar are siblings inside this wrapper. A
      // scrollbar declared inside the ListView would land in the flickable's
      // content item -- scrolling along with the rows and stretching to the
      // full content height -- which is what made it read as two bars.
      Item {
        id: listArea
        width: parent.width
        height: list.height
        visible: root.rows.length > 0

        // Handle only, no groove. A track drawn in the same foreground tint
        // reads as a second bar behind the first rather than as a channel.
        //
        // The hit area is wider than the 3px handle: a 3px drag target is
        // unusable with a mouse, so the surrounding padding is clickable and
        // only the handle is painted.
        Item {
          id: scrollTrack
          visible: root.listScrollable
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: root.listGutter

          readonly property real handleHeight: Math.max(Style.space(18),
            height * Math.min(1, list.visibleArea.heightRatio))
          // Travel available to the handle, and the matching travel in the
          // list's own content coordinates.
          readonly property real travel: Math.max(0, height - handleHeight)
          readonly property real contentTravel: Math.max(0, list.contentHeight - list.height)

          function scrollToHandleY(handleY) {
            if (travel <= 0) return
            var ratio = Math.max(0, Math.min(1, handleY / travel))
            list.contentY = ratio * contentTravel
          }

          Rectangle {
            id: scrollHandle
            width: Style.space(3)
            anchors.right: parent.right
            radius: width / 2
            color: root.foreground
            opacity: scrollArea.pressed ? 0.75
              : (scrollArea.containsMouse || list.moving ? 0.6 : 0.35)

            // Proportional handle. While dragging, the pointer drives it and
            // it drives the list; otherwise the list drives it.
            height: scrollTrack.handleHeight
            y: scrollArea.dragging
              ? scrollArea.dragY
              : scrollTrack.travel * (list.visibleArea.heightRatio >= 1
                ? 0
                : list.visibleArea.yPosition / Math.max(0.0001, 1 - list.visibleArea.heightRatio))

            Behavior on opacity { NumberAnimation { duration: 120 } }
          }

          MouseArea {
            id: scrollArea
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.ArrowCursor

            property bool dragging: false
            property real dragY: 0
            property real grabOffset: 0

            onPressed: function(mouse) {
              var handleTop = scrollHandle.y
              var handleBottom = handleTop + scrollTrack.handleHeight
              if (mouse.y >= handleTop && mouse.y <= handleBottom) {
                // Grabbed the handle: remember where along it, so it doesn't
                // jump to centre under the pointer.
                scrollArea.grabOffset = mouse.y - handleTop
              } else {
                // Clicked the empty gutter: jump so the handle centres there,
                // then continue as a drag.
                scrollArea.grabOffset = scrollTrack.handleHeight / 2
              }
              scrollArea.dragY = Math.max(0,
                Math.min(scrollTrack.travel, mouse.y - scrollArea.grabOffset))
              scrollArea.dragging = true
              scrollTrack.scrollToHandleY(scrollArea.dragY)
            }

            onPositionChanged: function(mouse) {
              if (!scrollArea.dragging) return
              scrollArea.dragY = Math.max(0,
                Math.min(scrollTrack.travel, mouse.y - scrollArea.grabOffset))
              scrollTrack.scrollToHandleY(scrollArea.dragY)
            }

            onReleased: scrollArea.dragging = false
            onCanceled: scrollArea.dragging = false
          }
        }

      ListView {
        id: list
        // Narrower than the wrapper by the scrollbar's gutter, so rows end
        // before the bar begins instead of running underneath it.
        width: parent.width - root.listGutter
        height: Math.min(contentHeight, Style.space(380))
        spacing: Style.space(4)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        // Wheel scrolling in smaller, eased steps than the default jump.
        flickDeceleration: 6000
        maximumFlickVelocity: 2500

        onContentHeightChanged: root.listScrollable = contentHeight > height
        onHeightChanged: root.listScrollable = contentHeight > height

        model: root.rows
        currentIndex: root.selectedIndex

        // ListView scrolls itself to keep the current item visible whenever
        // currentIndex changes, and hover sets that index -- which is the
        // real reason grazing a half-visible row yanked the list. Gating my
        // own positionViewAtIndex call was not enough; this is the built-in
        // behaviour behind it. Scrolling is now driven only by the explicit
        // call below.
        highlightFollowsCurrentItem: false

        // Keyboard navigation scrolls the view; mouse hover must not. Hover
        // sets the same cursor index j/k does, so scrolling on every index
        // change meant grazing a half-visible row at the edge yanked the
        // list -- the user was moving the pointer, not asking to scroll.
        onCurrentIndexChanged: {
          if (currentIndex < 0) return
          if (!root.keyboardCursor) return
          positionViewAtIndex(currentIndex, ListView.Contain)
        }

        // Wrapper takes ListView's delegate context, which doesn't bind into
        // nested `component` declarations, and passes it down explicitly.
        delegate: Item {
          required property var modelData
          required property int index

          // Header at each bucket boundary. The first row always gets one --
          // even an all-read list -- because the header row carries "Clear
          // all", and that has to stay reachable whatever the list contains.
          readonly property string sectionTitle: {
            if (index === 0) return modelData.unread ? "UNREAD" : "EARLIER"
            var prev = root.rows[index - 1]
            if (prev && prev.unread && !modelData.unread) return "EARLIER"
            return ""
          }

          width: ListView.view.width
          height: column.implicitHeight

          Column {
            id: column
            width: parent.width
            spacing: Style.space(4)

            // Section header, with "Clear all" riding the first one. Putting
            // it on the header row keeps it at the top of the list where the
            // eye already is, and on the *first* header only -- repeating it
            // over EARLIER would imply it clears just that section, which it
            // does not.
            Item {
              width: parent.width
              visible: sectionTitle !== ""
              height: visible ? sectionLabel.implicitHeight : 0

              PanelSectionHeader {
                id: sectionLabel
                // Matches the row content's inset so the header sits at the
                // same x as the gutter rule below it.
                x: Style.space(10)
                text: sectionTitle
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                id: clearAction
                visible: index === 0
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: sectionLabel.verticalCenter
                text: "Clear all"
                color: clearMouse.containsMouse ? root.foreground : root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                Behavior on color { ColorAnimation { duration: 90 } }

                MouseArea {
                  id: clearMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.clearAll()
                }
              }
            }

            NotificationRow {
              width: parent.width
              row: modelData
              rowIndex: index
            }
          }
        }
      }
      }

      // --------------------------------------------------------- empty
      Item {
        width: parent.width
        height: Style.space(120)
        visible: root.rows.length === 0

        Text {
          anchors.centerIn: parent
          text: root.dnd ? "Notifications are silenced" : "Nothing here"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      // -------------------------------------------------------- actions
    }

    // ------------------------------------------------------- context menu
    //
    // Click-away catcher underneath the menu itself, so a click anywhere
    // else closes it without also hitting the row it lands on.
    MouseArea {
      anchors.fill: parent
      visible: root.menuOpen
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onPressed: root.closeRowMenu()
    }

    BorderSurface {
      id: rowMenu
      visible: root.menuOpen
      // Keep the menu on-screen when the click lands near an edge.
      x: Math.max(0, Math.min(root.menuX, panelBody.width - width))
      y: Math.max(0, Math.min(root.menuY, panelBody.height - height))
      width: menuItems.implicitWidth + Style.space(16)
      height: menuItems.implicitHeight + Style.space(10)
      radius: Style.cornerRadius
      color: Color.popups.background
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

      // Two groups, split by the rule: the top acts on this one
      // notification, the bottom changes what happens from now on.
      Column {
        id: menuItems
        anchors.centerIn: parent
        spacing: Style.space(1)

        MenuEntry {
          label: "Open"
          onTriggered: {
            var target = root.menuRow
            root.closeRowMenu()
            root.activateRow(target)
          }
        }

        MenuEntry {
          label: "Dismiss"
          onTriggered: {
            root.dismiss(root.menuRow)
            root.closeRowMenu()
          }
        }

        Item {
          width: parent.width
          height: Style.space(7)

          PanelSeparator {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            foreground: root.foreground
          }
        }

        // The two ends of the same axis: one keeps a sender out of the list
        // entirely, the other keeps it coming through even when everything
        // else is silenced. They contradict each other, so a sender that is
        // set to never silence isn't offered "never show" -- turn the
        // exemption off first and the option comes back.
        MenuEntry {
          visible: !root.isAlwaysShown(root.menuRow ? root.menuRow.app : "")
          label: root.menuRow
            ? "Never show " + root.displayName(root.menuRow) + " again"
            : "Never show again"
          onTriggered: root.muteSource(root.menuRow)
        }

        // "Silence" is the same word the bell popup and its Silence button
        // use, so this reads as the sender opting in or out of that switch
        // rather than introducing "DND" as a term the UI never uses
        // elsewhere.
        MenuEntry {
          visible: root.canExemptApps
          label: root.isAlwaysShown(root.menuRow ? root.menuRow.app : "")
            ? "Silence"
            : "Never silence"
          onTriggered: root.toggleAlwaysShow(root.menuRow)
        }
      }
    }
    }
  }

  // Row in the context menu. Same hover treatment as a panel row so the two
  // surfaces feel like one kit.
  component MenuEntry: CursorSurface {
    id: entry
    property string label: ""
    signal triggered()

    width: Math.max(implicitLabelWidth, Style.space(150))
    readonly property real implicitLabelWidth: entryLabel.implicitWidth + Style.space(20)
    implicitWidth: width
    height: Style.space(26)

    hasCursor: entryMouse.containsMouse
    foreground: root.foreground
    fill: root.hoverFill

    Text {
      id: entryLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: entry.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    MouseArea {
      id: entryMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: entry.triggered()
    }
  }

  // ------------------------------------------------------------------- row

  component NotificationRow: CursorSurface {
    id: rowRoot
    required property var row
    required property int rowIndex

    readonly property bool selected: root.cursorActive && root.selectedIndex === rowIndex
    readonly property var source: root.sourceFor(row.app)
    // Senders that pass no icon of their own borrow their source's desktop
    // icon, which is why Discord and Sable rows get real artwork.
    readonly property string iconPath: {
      var own = root.iconSource(row.appIcon)
      if (own !== "") return own
      return source ? root.iconSource(source.desktopIcon) : ""
    }
    readonly property bool hasImage: row.image !== ""
    readonly property string bodyText: BodyText.clean(row.body, row.app, row.appIcon)
    readonly property color sourceColor: source ? source.color : root.dim
    readonly property string sourceLabel: source ? source.label : row.app

    hasCursor: selected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX

    // Swipe-to-dismiss. The row follows the pointer horizontally and fades
    // as it goes; past the threshold it flies out and is dropped, otherwise
    // it springs back. Distance is scaled to the row so the gesture feels the
    // same on a narrow panel as a wide one.
    property real swipe: 0
    readonly property real swipeLimit: Math.max(Style.space(40), width * 0.2)

    // A dismissed row leaves its delegate holding a full swipe offset and a
    // faded opacity. If the view hands that delegate to another row, the
    // replacement would arrive already flung off-screen and invisible, so
    // reset whenever the row this delegate represents changes.
    onRowChanged: {
      flingOut.stop()
      swipe = 0
    }

    transform: Translate { x: rowRoot.swipe }
    opacity: 1 - Math.min(0.85, Math.abs(swipe) / Math.max(1, swipeLimit))

    // Animate the spring-back, but not the drag itself -- the row has to
    // track the pointer 1:1 while the button is down.
    Behavior on swipe {
      enabled: !rowMouse.swiping
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    function settleSwipe() {
      if (Math.abs(rowRoot.swipe) < rowRoot.swipeLimit) {
        rowRoot.swipe = 0
        return
      }
      // Fling it the rest of the way out, then drop it. Removing the row
      // mid-animation would yank the delegate out from under the animation.
      flingOut.to = rowRoot.swipe > 0 ? rowRoot.width : -rowRoot.width
      flingOut.start()
    }

    NumberAnimation {
      id: flingOut
      target: rowRoot
      property: "swipe"
      duration: 120
      easing.type: Easing.OutCubic
      onFinished: root.dismiss(rowRoot.row)
    }

    // Click and swipe share one MouseArea. They can't be split across two
    // stacked areas: only the top area receives a press, and declining it
    // (mouse.accepted = false) hands the whole gesture to the area below,
    // so the decliner never sees the move events a drag is made of.
    //
    // `drag.target` is also unused on purpose. It would move the row by
    // reparenting geometry, which fights the ListView's own layout; driving
    // a Translate transform from the pointer delta leaves layout alone.
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      preventStealing: true
      cursorShape: Qt.PointingHandCursor

      // Where the press landed, in the parent's coordinates (see
      // onPositionChanged), and whether the pointer has since travelled far
      // enough to count as a swipe rather than a click with a shaky hand.
      property real pressPointer: 0
      property bool swiping: false
      readonly property real swipeThreshold: Style.space(4)

      onContainsMouseChanged: {
        // Ignore hover changes mid-swipe: the row slides out from under a
        // stationary pointer, and reacting to that would fight the gesture.
        if (rowMouse.swiping) return
        if (containsMouse) root.setCursor(rowRoot.rowIndex)
        else root.clearCursor(rowRoot.rowIndex)
      }

      onPressed: function(mouse) {
        rowMouse.pressPointer = rowMouse.mapToItem(rowRoot.parent, mouse.x, mouse.y).x
        rowMouse.swiping = false
        flingOut.stop()
      }

      onPositionChanged: function(mouse) {
        if (!rowMouse.pressed || mouse.buttons !== Qt.LeftButton) return

        // mouse.x is measured inside this row, and the row itself is moving
        // as it swipes -- so a raw delta subtracts a distance that already
        // includes the offset it is about to produce. That feedback is what
        // made a slow drag stutter: each frame partially cancelled the last.
        // Mapping to the parent gives a fixed frame of reference.
        var pointer = rowMouse.mapToItem(rowRoot.parent, mouse.x, mouse.y).x
        var delta = pointer - rowMouse.pressPointer

        if (!rowMouse.swiping) {
          if (Math.abs(delta) < rowMouse.swipeThreshold) return
          rowMouse.swiping = true
          // Start from zero rather than jumping the row by the threshold
          // distance the moment the gesture is recognised.
          rowMouse.pressPointer = pointer
          delta = 0
        }

        rowRoot.swipe = delta
      }

      onReleased: function(mouse) {
        if (rowMouse.swiping) {
          rowMouse.swiping = false
          rowRoot.settleSwipe()
          return
        }
        // Not a swipe, so it was a click. Handled here rather than in
        // onClicked because a press that moved at all suppresses onClicked.
        if (mouse.button === Qt.RightButton) {
          var point = rowMouse.mapToItem(panelBody, mouse.x, mouse.y)
          root.openRowMenu(rowRoot.row, point.x, point.y)
        } else {
          root.activateRow(rowRoot.row)
        }
      }

      onCanceled: {
        rowMouse.swiping = false
        rowRoot.settleSwipe()
      }
    }

    // Content is inset so the hover fill has padding around it, and the
    // section headers take the same inset (see the delegate) so the gutter
    // rule still lines up with them. Insetting only one of the two is what
    // put the rule and the headers on different x positions.
    //
    // The scrollbar gutter is taken out of the ListView's width rather than
    // here, so rows simply end before the bar starts.
    Item {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: text.implicitHeight

      // One gutter rule carries both signals: its color is the source, and
      // its strength is the unread state. A separate dot would have been a
      // third mark saying what the rule and the bold summary already say.
      Rectangle {
        id: sourceRule
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(2)
        radius: width / 2
        color: rowRoot.sourceColor
        opacity: rowRoot.row.unread ? 1.0 : 0.35
      }

      // Sender identity, in descending order of how much it tells you:
      // the notification's own image (an avatar, usually), the app icon, the
      // app's glyph, and finally its initial. A generic bell on every row
      // would be pure decoration -- it repeats what the panel already says.
      Column {
        id: text
        anchors.left: sourceRule.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        // Source line: small app icon, source name, and the time. The icon
        // rides at label height rather than sitting in its own column, so the
        // message text starts at the left edge instead of being indented past
        // an avatar gutter.
        Item {
          width: parent.width
          implicitHeight: Math.max(sourceLabel.implicitHeight, Style.space(13))

          Item {
            id: avatar
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(13)
            height: Style.space(13)

            readonly property string source: rowRoot.hasImage
              ? root.iconSource(rowRoot.row.image)
              : rowRoot.iconPath
            readonly property bool imageOk: source !== "" && picture.status === Image.Ready
            readonly property string fallbackGlyph: {
              if (rowRoot.row.glyph !== "") return rowRoot.row.glyph
              return rowRoot.source ? rowRoot.source.glyph : ""
            }

            Text {
              anchors.centerIn: parent
              visible: !avatar.imageOk
              text: avatar.fallbackGlyph !== ""
                ? avatar.fallbackGlyph
                : rowRoot.row.app.charAt(0).toUpperCase()
              color: rowRoot.row.urgency === 2 ? Color.urgent : rowRoot.sourceColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Image {
              id: picture
              anchors.fill: parent
              visible: avatar.imageOk
              source: avatar.source
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              asynchronous: true
              smooth: true
            }
          }

          // Source name: the fastest thing to scan for, and what tells you
          // whether the rest of the row is worth reading. Colored to match
          // the gutter rule so the two read as one signal.
          Text {
            id: sourceLabel
            anchors.left: avatar.right
            anchors.leftMargin: Style.space(6)
            anchors.right: timeLabel.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: rowRoot.sourceLabel
            color: rowRoot.sourceColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            id: timeLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.relativeTime(rowRoot.row.timestamp)
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          visible: rowRoot.row.summary !== ""
          text: rowRoot.row.summary
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          // Weight carries unread as well as the dot, so the state survives
          // for anyone who can't pick the accent color out.
          font.bold: rowRoot.row.unread
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: rowRoot.bodyText !== ""
          text: rowRoot.bodyText
          textFormat: Text.PlainText
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }

    }
  }
}
