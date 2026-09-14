![Notification Center banner showing a bell with an unread badge beside the product name](https://raw.githubusercontent.com/abran-labs/omarchy-notification-center/master/.github/assets/notification-center-banner.svg)

# Notification Center

**Every notification you missed, in the Omarchy bar.**

## Install

```sh
omarchy plugin add https://github.com/abran-labs/omarchy-notification-center.git --enable
```

Remove with:

```sh
omarchy plugin remove abran-labs.notification-center --yes
```

Requires Omarchy 4 with the `omarchy.notifications` service.

![The notification center open in the bar, showing unread and earlier notifications from Vesktop, Sable, and Spotify](https://raw.githubusercontent.com/abran-labs/omarchy-notification-center/master/.github/assets/preview.png)

## Commands

```sh
omarchy-shell notification-center toggle   # open or close the panel
omarchy-shell notification-center clear    # empty the list
omarchy-shell notification-center unread   # print the unread count
```

## Compatibility

Works with both generations of the `omarchy.notifications` service, without
changing the service:

- Old services expose `pendingModel` / `pastModel`; those are used directly.
- Current upstream keeps only `popupModel` and files every finished toast to
  `~/.local/state/omarchy/notifications/history/` (one JSON row per file).
  The widget then keeps its own models, fed by live popup rows plus a bounded
  poll of that directory (every 5s and on every new toast) — polling is the
  only way to see DND-silenced notifications, which never pop.

Own read/dismiss state (including `archive` rows) persists to
`~/.local/state/omarchy/notification-center.json` and is keyed by
timestamp+originalId, since server ids restart from 1. Dismissing records a
tombstone instead of touching service files, so dismissed rows stay gone;
`clear` leaves on-screen toasts alone, matching the service's own `clear`.
DND itself stays on the native service.
