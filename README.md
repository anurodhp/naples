# Naples

A Dock for GNUstep + Window Maker on Darwin/XNU (the `iokit` Pi port), companion to [Milan](../milan).
Pure AppKit + Xlib + libdispatch; no extra libraries beyond the X11 ones the stack already has.

- **Bottom bar** (drag the bar's background to the left or right edge to move it; the choice persists).
  Left to right: **Milan** (fixed), your **pinned apps**, a divider, **running programs** that are not pinned,
  **minimized windows**, **Trash** (fixed).
- Click an app to start it; click a running one to bring its window forward (un-minimizing it). A **white dot**
  marks running apps (on the screen-edge side of the icon).
- **Long click** (0.5 s) or right-click: menu with Show / **Quit** (SIGTERM) / **Force Quit** (SIGKILL), Keep in Dock /
  Remove from Dock. On the Trash: Open / Empty. On a minimized window: Restore / Close. On the bar: move, Quit Naples.
- **Drag** `.app` bundles in from Milan, drag icons to reorder, drag an icon off the dock to remove it. Dropping files
  on the Trash moves them to `~/.Trash` (Put Back info in Milan's `.milan-origins` format); dropping a document on an
  app icon opens it with that app.
- Transparent bar with 5px corners: the corners are an XShape mask (works without a compositor); the fill is drawn
  translucent and `_NET_WM_WINDOW_OPACITY` is set, so real see-through needs an alpha-capable window or a compositor.
- Reserves its strip with `_NET_WM_STRUT_PARTIAL` so maximized windows stop at the dock (`NaplesReserveSpace NO` to disable).

## How the pieces use XNU / GCD

- Running state: `_NET_CLIENT_LIST` + `WM_STATE` via a GCD read source on the X connection; a window's process and bundle
  come from `sysctl(KERN_PROCARGS2)`.
- Children Naples starts are watched with `DISPATCH_SOURCE_TYPE_PROC` (kqueue `EVFILT_PROC`/`NOTE_EXIT`).
- The Trash can fills/empties from a `DISPATCH_SOURCE_TYPE_VNODE` source on `~/.Trash`; moves to the Trash run on a global queue.

## Taking over minimizing

Window Maker only skips drawing miniwindows when `DisableMiniwindows = YES` (a stock option, no WM patch). At start Naples
writes that into `$GNUSTEP_USER_ROOT/Defaults/WindowMaker` (default `~/GNUstep/Defaults/WindowMaker`) unless
`-NaplesTakeOverMinimize NO`; Window Maker re-reads its defaults on its own. Minimized windows then stay in
`_NET_CLIENT_LIST` with `WM_STATE = Iconic`, which is what the dock lists; clicking one sends `_NET_ACTIVE_WINDOW`, which Window
Maker answers by de-iconifying.

## Build

`./build.sh` (cross-builds with the iokit checkout, `IOKIT_DIR` defaults to `../iokit`; same recipe as Milan's),
`./build.sh deploy` copies `Naples.app` to the Pi. Start it from the session autostart after Window Maker.

## Defaults

`NaplesIconSize` (44), `NaplesEdge` (0 bottom, 1 left, 2 right), `NaplesReserveSpace`, `NaplesMilanPath`,
`NaplesTakeOverMinimize`. `NaplesPinned` is the pinned list (first run seeds it from `/Applications`).

## Status

Builds clean (`-Wall`). **Not yet run on the Pi.** Things to check first, per Milan's `docs/notes.md`: that the borderless
dock window paints (a repaint is forced 0.5 s after launch), that drag and drop from Milan and within the dock works,
that the menu overlay grows the window correctly on all three edges, and whether the dock renders translucent or solid.
