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
