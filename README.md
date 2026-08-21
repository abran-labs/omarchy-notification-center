![Notification Center banner showing a bell with an unread badge beside the product name](https://raw.githubusercontent.com/abran-labs/omarchy-notification-center/master/.github/assets/notification-center-banner.svg)

# Notification Center

**Every notification you missed, in the Omarchy bar.**

## Install

```sh
omarchy plugin add https://github.com/abran-labs/omarchy-notification-center.git --enable
```

## What it does

A toast you were not at your desk for is gone forever. This keeps it, in a list you can act on later.

| Action | Result |
| --- | --- |
| Click | Opens the app on that message |
| Right click | Menu: open, dismiss, per-app rules |
| Swipe sideways | Dismiss |
| Read it in the app | Clears itself |

## Per-app rules

Right click any notification.

| Rule | Effect |
| --- | --- |
| `Never show again` | Still notifies, never lands in the list |
| `Never silence` | Still notifies while everything else is silenced |

Right click the bell to see both lists and undo anything.

## Commands

```sh
omarchy-shell notification-center toggle    # bind to a key
omarchy-shell notifications dismissAll      # clear the list
```

## Requires

Omarchy 4 with the first-party `omarchy.notifications` service. No second daemon.

## License

MIT
