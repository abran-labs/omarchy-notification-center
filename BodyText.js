.pragma library

// Cleanup for notification body text before it is rendered in a row.
//
// Two problems to solve, both from senders that route notifications through a
// browser engine:
//
//   1. Embedded <img> markup. The body is rendered as plain text, so any
//      markup a sender includes would otherwise show up literally.
//
//   2. A leading origin. Chromium-based browsers prepend the originating site
//      to web-notification bodies ("app.example.com  Alice: hey"), which is
//      redundant here because the row already names the sender in its own
//      line. Stripping it keeps the body starting on the actual message.
//
// The origin strip is deliberately limited to browser-derived senders. A
// native app that happens to start a message with a URL should keep it: that
// URL is content, not chrome.

// Browser engines that prefix bodies with the originating site. Matched
// loosely against both the app name and its icon name, because which of the
// two carries the identifying string varies by sender.
var BROWSER_HINTS = ["chrom", "brave", "vivaldi", "edge", "opera"]

function isBrowserDerived(app, appIcon) {
  var haystack = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
  for (var i = 0; i < BROWSER_HINTS.length; i++) {
    if (haystack.indexOf(BROWSER_HINTS[i]) !== -1) return true
  }
  return false
}

// A bare domain, optionally with scheme, port, and path: the shape Chromium
// uses for its origin prefix.
var ORIGIN = "(?:https?:\\/\\/)?(?:www\\.)?(?:[a-z0-9-]+\\.)+[a-z]{2,}(?::\\d+)?(?:\\/[^\\s<]*)?"

// The prefix as a link element, which is how it arrives when the sender
// supplies markup.
var LINKED_ORIGIN = new RegExp("^\\s*<a\\b[^>]*>\\s*" + ORIGIN + "\\s*<\\/a>\\s*", "i")

// The same prefix as bare text, requiring whitespace after it so a body that
// is *only* a URL is left alone.
var BARE_ORIGIN = new RegExp("^\\s*" + ORIGIN + "\\s+", "i")

function stripMarkup(text) {
  return String(text || "").replace(/<img[^>]*>/gi, "")
}

function stripOriginPrefix(text) {
  var stripped = text.replace(LINKED_ORIGIN, "")
  if (stripped !== text) return stripped
  return text.replace(BARE_ORIGIN, "")
}

// Entry point: body as the sender wrote it, plus enough about the sender to
// decide whether an origin prefix is chrome or content.
function clean(body, app, appIcon) {
  var text = stripMarkup(body)
  if (!isBrowserDerived(app, appIcon)) return text
  return stripOriginPrefix(text)
}
