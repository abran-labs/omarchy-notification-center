.pragma library

// A "source" is a sender the panel knows how to present: what to call it,
// what color to tint its rows, which glyph to fall back to when it sends no
// icon, and which window to raise when a row is clicked.
//
// Senders that match nothing still appear. They just render with their own
// app name and the neutral foreground, so no notification is ever dropped for
// want of an entry here.
//
// Matching is done on the sender's `app_name` as lowercase substrings,
// because that string is not stable: the same app shows up as "Vesktop" and
// "vesktop" depending on how it was launched, and browser-based clients
// report the browser rather than themselves.

var DEFAULTS = [
  {
    key: "discord",
    label: "Discord",
    match: ["vesktop", "discord", "vencord", "webcord"],
    glyph: "\udb81\ude4f",
    color: "#e0574a",
    desktopIcon: "vesktop",
    focusClass: "vesktop"
  },
  {
    key: "matrix",
    label: "Matrix",
    match: ["sable", "element", "cinny", "fractal", "nheko"],
    glyph: "\udb81\uded9",
    color: "#a78bfa",
    desktopIcon: "element",
    focusClass: "element|sable|cinny"
  },
  {
    key: "slack",
    label: "Slack",
    match: ["slack"],
    glyph: "\udb84\udcc1",
    color: "#4a9d7f",
    desktopIcon: "slack",
    focusClass: "slack"
  },
  {
    key: "telegram",
    label: "Telegram",
    match: ["telegram"],
    glyph: "\udb84\udd95",
    color: "#5aa7d6",
    desktopIcon: "telegram",
    focusClass: "telegram"
  },
  {
    key: "signal",
    label: "Signal",
    match: ["signal"],
    glyph: "\udb84\udc9a",
    color: "#5b8ce0",
    desktopIcon: "signal-desktop",
    focusClass: "signal"
  },
  {
    key: "mail",
    label: "Mail",
    match: ["thunderbird", "evolution", "geary", "mailspring"],
    glyph: "\udb80\udeed",
    color: "#d4a35c",
    desktopIcon: "thunderbird",
    focusClass: "thunderbird|evolution|geary"
  },
  {
    key: "music",
    label: "Music",
    match: ["spotify", "rhythmbox", "tauon"],
    glyph: "\udb80\udd1e",
    color: "#6fbf73",
    desktopIcon: "spotify",
    focusClass: "spotify"
  }
]

// isArrayLike rather than Array.isArray: values handed in from QML are
// built in another JavaScript context and fail an isArray check even when
// they are arrays. See the note in Rules.js.
function isArrayLike(value) {
  return !!value && typeof value !== "string" && typeof value.length === "number"
}

function normalize(entry) {
  if (!entry || typeof entry !== "object") return null
  var match = entry.match
  if (typeof match === "string") match = [match]
  if (!isArrayLike(match) || match.length === 0) {
    // An entry with nothing to match on can still be useful if it names a
    // key: treat the key itself as the pattern.
    match = entry.key ? [String(entry.key)] : []
  }
  if (match.length === 0) return null

  return {
    key: String(entry.key || match[0]),
    label: String(entry.label || entry.key || match[0]),
    match: match.map(function(m) { return String(m).toLowerCase() }),
    glyph: String(entry.glyph || ""),
    color: String(entry.color || ""),
    desktopIcon: String(entry.desktopIcon || ""),
    focusClass: String(entry.focusClass || entry.key || match[0]),
    launch: String(entry.launch || "")
  }
}

// User entries win over the built-ins they collide with, so overriding one
// app's color or launch command does not mean restating the whole table.
// A user entry with `"enabled": false` removes a built-in outright.
function resolve(userSources) {
  var out = []
  var overrides = {}
  var disabled = {}

  if (isArrayLike(userSources)) {
    for (var i = 0; i < userSources.length; i++) {
      var raw = userSources[i]
      if (!raw || typeof raw !== "object") continue
      var key = String(raw.key || "")
      if (key && raw.enabled === false) {
        disabled[key] = true
        continue
      }
      var entry = normalize(raw)
      if (!entry) continue
      if (key) overrides[key] = entry
      else out.push(entry)
    }
  }

  for (var d = 0; d < DEFAULTS.length; d++) {
    var base = DEFAULTS[d]
    if (disabled[base.key]) continue
    if (overrides[base.key]) {
      out.push(merge(normalize(base), overrides[base.key]))
      delete overrides[base.key]
      continue
    }
    out.push(normalize(base))
  }

  // Anything the user defined that did not correspond to a built-in.
  for (var k in overrides) out.push(overrides[k])

  return out
}

function merge(base, override) {
  var result = {}
  for (var k in base) result[k] = base[k]
  for (var j in override) {
    if (override[j] !== "" && override[j] !== undefined && override[j] !== null)
      result[j] = override[j]
  }
  return result
}

// First source whose patterns appear in the sender's app name, or null.
function forApp(sources, app) {
  var name = String(app || "").toLowerCase()
  if (!name) return null
  for (var i = 0; i < sources.length; i++) {
    var patterns = sources[i].match
    for (var j = 0; j < patterns.length; j++) {
      if (name.indexOf(patterns[j]) !== -1) return sources[i]
    }
  }
  return null
}
