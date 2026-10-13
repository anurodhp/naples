<p align="center"><img src="doc/header.png" alt="Naples running on a Raspberry Pi 3 under Darwin: the dock along the bottom, the menu bar across the top with the Sound panel open" width="100%"></p>

# Naples

**A dock and menu bar for a small Darwin desktop.** Naples is the dock and global menu bar for the GNUstep + Window Maker desktop on the Raspberry Pi 3 port of Darwin/XNU (the sibling repository [iokit](https://github.com/anurodhp/xnu-iokit-pi3)). It is a companion to [Milan](https://github.com/anurodhp/milan), the file manager and desktop. Pure AppKit + Xlib + libdispatch; no libraries beyond the X11 ones the stack already has.

## What you can do

**Dock** (bottom by default; drag the bar's background to the left or right edge and the choice persists). Left to right: **Milan** (fixed), your **pinned apps**, a divider, **running programs** that are not pinned, **minimized windows**, **Trash** (fixed).

- Click an app to start it; click a running one to bring its window forward (un-minimizing it). A white dot marks running apps, including ones with no normal window (such as Milan drawing the desktop).
- Rest the pointer on an icon for half a second to see its name.
- Long click (0.5 s) or right-click for a menu: Show / Quit (SIGTERM) / Force Quit (SIGKILL), Keep in Dock / Remove from Dock. On the Trash: Open / Empty. On a minimized window: Restore / Close. On the bar: move, Quit Naples.
- Drag `.app` bundles in from Milan, drag icons to reorder, drag an icon off the dock to remove it. Drop a document on an app icon to open it with that app.
- Drop files on the Trash to move them to `~/.Trash` (Put Back info in Milan's `.milan-origins` format).
- Maximized windows stop at the dock (it reserves its strip with `_NET_WM_STRUT_PARTIAL`).

**Menu bar** across the top: a Hexley head at the far left, the frontmost app's menus, and the volume and the date and time at the far right. The Hexley menu has About Naples, Open Milan, dock position, **Log Out, Restart and Shut Down** (each asks first), and Quit Naples.

**Volume**: a speaker left of the clock whose waves (none to three) follow the volume. Click it for a small Sound panel with a slider. It sets the device volume of iokit's audio daemon `audiod`, which keeps it across restarts; without audio on the image the speaker is not shown.

**Wi-Fi**: a Wi-Fi fan left of the speaker whose arcs follow the signal. All arcs are faint when Wi-Fi is on but not connected, and faint with a slash when it is off. Click it for the Wi-Fi panel:
- an on/off switch;
- the network you are connected to;
- the networks in range, strongest first, with a lock on secured ones.

Click a network to join it; a secured one that is not the remembered network asks for its password. **Option-click** (Alt) also shows the connection's details: IP address, router, BSSID, channel and band, security, 802.11 protocol, RSSI, noise and transmit rate. For the remembered network it adds **Forget This Network…**: after a confirmation, it leaves the network, removes it from `/etc/wifi.conf` so it is not joined again at boot or when Wi-Fi is turned on, and releases en1's address. It needs iokit's WiFi driver (boot-arg `wifi=1`); without it the icon is not shown.

## What you cannot do (yet)

- No true see-through bar: the corners are an XShape mask and the fill is drawn translucent with `_NET_WM_WINDOW_OPACITY`, but real transparency needs a compositor or an alpha-capable window.
- Apps that are not GNUstep apps running the Eau theme show only their name in the menu bar; they cannot push a menu.
- Naples must be started before the other apps. An app that outlives a Naples restart is asked for its menu again, but reconnection depends on Eau.
- No Spaces, no window previews on minimized items, no badges or bouncing icons.
- Restart and Shut Down rely on iokit's session script (gsdm Xsession) reading `$HOME/.session-request`; without it only Log Out works.
- Darwin only (it uses `sysctl`, `kinfo_proc` and kqueue). It does not build on Linux.
- Building needs a Mac and the iokit toolchain. There is no prebuilt package.

## How it works

Naples draws the bar and the dock as borderless X windows from AppKit, and reads the window manager's EWMH state over a GCD source on the X connection.

- The clock redraws on a wall-clock-aligned `DISPATCH_SOURCE_TYPE_TIMER`.
- The volume goes through the CoreAudio HAL calls of `/usr/lib/libaudiohal.dylib` (opened with `dlopen`), on a serial GCD queue: each call is a Mach RPC to `audiod`. The library has no property listeners, so a volume another program sets shows when the Sound panel is next opened.
- Wi-Fi talks to iokit's `BCM43430Wifi` driver through its user client, with IOKitLib opened by `dlopen` from `/usr/lib/libiokituser.dylib`. Calls run on a serial GCD queue, because a scan takes seconds and a join up to 20 s. The ABI header is iokit's `iokit/BCM43430Wifi/BCM43430WifiShared.h`; `build_naples.sh` puts it on the include path.
  - A join remembers the network in `/etc/wifi.conf` (mode 600), which iokit's boot job joins at startup, and gets an address with `ipconfig set en1 DHCP`.
  - Turning Wi-Fi off leaves `/etc/wifi.off`, so it stays off after a reboot.
  - Option is read from the X server (`XQueryPointer`), because GNUstep fills an event's modifier flags only for a focused window, and the bar never has focus.
  - The status is polled every 5 s, or 2 s while the panel is open; the panel rescans every 15 s while it is open.
- Running state: `_NET_CLIENT_LIST` + `WM_STATE`, plus a process scan for apps with no normal window; a window's process and bundle come from `sysctl(KERN_PROCARGS2)`.
- Children Naples starts are watched with `DISPATCH_SOURCE_TYPE_PROC` (kqueue `EVFILT_PROC`/`NOTE_EXIT`).
- The Trash can fills/empties from a `DISPATCH_SOURCE_TYPE_VNODE` source on `~/.Trash`; moves to the Trash run on a global queue.
- Log Out asks open applications to close their windows, then ends Window Maker (which is the session). Restart and Shut Down first leave a request in `$HOME/.session-request` (the session's HOME, not GNUstep's home folder, which for root is `/`) for the session script, which turns it into the exit status gsdm acts on.

## Menu bar

A second window across the top (`NaplesBar`): a **Hexley head** at the far left (opens a system menu: About Naples, Open Milan, dock
position, Quit Naples), the **frontmost app's menu titles** after it, and **Wi-Fi**, the **volume** and the **date and time** at the far right. It
reserves its strip with a strut. Disable with `-NaplesBar NO`.

It is the server end of the Eau theme's menu protocol (Distributed Objects, `org.gnustep.Gershwin.MenuServer`, see
`NaplesMenuProtocol.h`, identical to Eau.h). Each app running Eau pushes its menu here and hides its own menu bar; Naples
shows the menu of the app whose window is `_NET_ACTIVE_WINDOW` (via `_NET_WM_PID` -> `MenuClient.<pid>`), refreshes
enabled/checked state with `validateMenuStateForWindow:` right before a menu opens, and sends the chosen item back as an
index path. Drop-downs and cascades are small borderless windows of their own (`NaplesPanel`), one per level, sized exactly to the
menu; growing the bar window to hold them left its unused part painted black on this server. The dock's long-click menu
uses the same panels.

Start Naples before the other apps (the session autostart): Eau looks the server up when it starts and retries every
30 s. An app that outlives a Naples restart keeps a dead connection until its next push, so Naples asks every process for
its menu one second after it starts (`requestApplicationMenuUpdate`), which makes Eau reconnect. Apps that are not GNUstep/Eau show just their name.

## Taking over minimizing

Window Maker only skips drawing miniwindows when `DisableMiniwindows = YES` (a stock option, no WM patch). At start Naples
writes that into `$GNUSTEP_USER_ROOT/Defaults/WindowMaker` (default `~/GNUstep/Defaults/WindowMaker`) unless
`-NaplesTakeOverMinimize NO`; Window Maker re-reads its defaults on its own. Minimized windows then stay in
`_NET_CLIENT_LIST` with `WM_STATE = Iconic`, which is what the dock lists; clicking one sends `_NET_ACTIVE_WINDOW`, which Window
Maker answers by de-iconifying.

## Building

You need a Mac with **Xcode 12** (the iPhoneOS SDK the port is built with) and a current Xcode for its linker, and the [iokit](https://github.com/anurodhp/xnu-iokit-pi3) repository checked out next to this one (`../iokit`, or set `IOKIT_DIR`) with its toolchain and GNUstep libraries already built.

```sh
./build.sh            # cross-build; Naples.app lands in iokit's libc_build/gnustep/root
./build.sh deploy     # build, then copy Naples.app and Milan.app to the Pi
```

`deploy` uses `DEPLOY_HOST` (default `root@10.0.0.142`). It stops Naples and Milan on the Pi first, because replacing a running app's files has taken the whole X session down. Start Naples from the session autostart, after Window Maker and before the other apps.

## Defaults

`NaplesIconSize` (44), `NaplesEdge` (0 bottom, 1 left, 2 right), `NaplesReserveSpace`, `NaplesMilanPath`,
`NaplesTakeOverMinimize`. `NaplesPinned` is the pinned list (first run seeds it from `/Applications`).

## Layout

| | |
|---|---|
| `NaplesDock.m`, `NaplesDockView.m` | the dock: items, running state, drag and drop, Trash |
| `NaplesBar.m`, `NaplesBarView.m` | the menu bar, the Eau menu server, the Hexley menu, power actions |
| `NaplesPanel.m` | borderless windows for drop-down menus and the confirmation panel |
| `NaplesX.m` | the X connection: EWMH, struts, shape masks |
| `NaplesMenuProtocol.h` | the menu protocol (identical to Eau.h) |
| `icons/`, `tools/make_icon.m` | Hexley head, the Naples icon and its generator |

## Licence

Naples is MIT licensed. The Hexley art is © 2000 Jon Hooper, all rights reserved, bundled under its own license as in Milan (`../milan/icons/app/README.md`), not under the MIT license.
