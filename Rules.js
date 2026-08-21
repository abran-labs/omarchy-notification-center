.pragma library

// Per-app rules, matched against a notification's `app_name`.
//
// Matching is case-insensitive substring rather than equality, because
// app_name is not a stable identifier. The same application reports itself
// differently depending on how it was started ("Vesktop" from a desktop
// entry, "vesktop" from a shell), and Electron apps in particular drift
// between releases. A substring rule survives that; an exact rule does not.
//
// The consequence worth knowing: a short rule matches broadly. A rule of
// "sig" would also catch a sender called "signal-desktop-beta". Rules are
// added from a notification's own app name, so in practice they are as
// specific as the sender that created them.

// Array.isArray is deliberately not used here. A `.pragma library` module
// runs in its own JavaScript context, and an array handed over from QML was
// constructed in a different one -- so it fails an isArray check despite
// being a perfectly good array. Duck-typing on `length` is what works across
// that boundary.
function list(value) {
  if (!value || typeof value === "string" || typeof value.length !== "number") return []
  var out = []
  for (var i = 0; i < value.length; i++) {
    var entry = String(value[i] || "").trim()
    if (entry) out.push(entry)
  }
  return out
}

function matches(rules, appName) {
  var name = String(appName || "").toLowerCase()
  if (!name || !rules || !rules.length) return false
  for (var i = 0; i < rules.length; i++) {
    var rule = String(rules[i] || "").toLowerCase()
    if (rule && name.indexOf(rule) !== -1) return true
  }
  return false
}

function add(rules, appName) {
  var entry = String(appName || "").trim()
  if (!entry) return list(rules)
  var next = list(rules)
  if (matches(next, entry)) return next
  next.push(entry)
  return next
}

// Removes every rule responsible for `appName` matching, not just an exact
// hit. Dropping only the exact match would strand the shorter substring
// rules that do the matching, leaving a toggle that refuses to turn off.
function remove(rules, appName) {
  var name = String(appName || "").trim().toLowerCase()
  if (!name) return list(rules)
  var next = []
  var current = list(rules)
  for (var i = 0; i < current.length; i++) {
    var rule = String(current[i]).toLowerCase()
    if (rule === name) continue
    if (name.indexOf(rule) !== -1) continue
    next.push(current[i])
  }
  return next
}
