# Changelog

All notable changes to Whiskr are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing has been released yet. This is what the first release will contain.

### Added

- A native macOS terminal for Claude Code: workspaces (one per folder), tabs and split panes of real
  terminals, drawn by SwiftTerm. The window follows herdr's arrangement, with the terminals on the right.
- The meadow, where the sidebar would be: a 3D clay scene with one picnic blanket per workspace and a
  black cat for every Claude running in its terminals, acting out what Claude is doing. Helpers sit beside
  their Claude. Requests ("!"), errors ("×") and finished turns ("✓") read by shape and mark as well as
  colour. Day, night with fireflies, and optional real weather. The meadow can also be shown as a plain
  list.
- A cat appears as soon as `claude` runs in any pane, however it was started. A `claude` shim on each
  pane's PATH adds hooks through `--settings`, so the user's own Claude Code settings are never changed.
- A session host inside the app owns every terminal, so quitting leaves everything running and the next
  launch reattaches each pane with its screen. Quit and Stop All Terminals (⌥⌘Q) ends them. After a
  restart, Claude panes offer `claude --resume`.
- Attention: Next Request (⌘J), three soft alert sounds, notifications with Allow and Deny while the app
  is in the background, a Dock badge and Dock menu, Pause Alerts, and Mark as Unread. An answer card
  answers a request without going to its terminal. No agent event ever moves the window, focus, tab or
  camera.
- Go to (⌘P) for workspaces, tabs, Claudes, helpers and files, and a command palette (⇧⌘P).
- Files and Changes beside the terminals. A light editor with syntax colouring for 23 languages, find and
  replace, and Go to Line. Markdown, image and PDF previews. Diffs side by side or inline. Staging,
  discarding and committing.
- Git worktrees as workspaces of their own, joined to their repository's blanket in the meadow.
- `paw`, a command-line tool on every terminal's PATH for starting and steering helper terminals (`run`,
  `send`, `wait`, `read`, `keys`, `interrupt`, `ls`, `kill`).
- Themes (built-in, your own `.whiskrtheme` files, and imported iTerm2 colour presets), terminal font and
  cursor settings, and Option as Meta.
- Home: where every launch lands and where closing a workspace returns you (Go › Home, ⇧⌘H). Beside the
  meadow it offers Open Folder…, New Terminal, the workspaces open now with their state (Return goes back
  in where you left off), and recent folders. Nothing is typed into a terminal at launch, except to
  resume a Claude whose terminal ended with a restart, and not even that while the earlier-named app's
  session host still runs.
- A window frame like a professional editor's: a top bar across the window (meadow button, Home, a search
  field that opens Go to, New, Files and Changes, Settings) and a status bar along its foot (branch,
  folder, Claudes and requests, the editor's details, ⌘P and ⇧⌘P), with the meadow and the work area
  between them. The bars, the tab row and the Files and Changes panel share one chrome colour a step
  below the terminals, with a clear line between every two regions; the bars go quiet when the window is
  not the one in use, and lines strengthen with Increase Contrast.
- Tabs as in Cursor and VS Code: the selected tab joins its terminal, with an accent line along its top;
  a close button at each tab's end (always on the selected tab, on the others under the pointer); a
  middle click closes; with more tabs than fit, the row shows those around the selected one and a menu
  lists them all, and "+" stays in reach. The tab
  row begins with the workspace's colour and name, whose menu lists every workspace.
- In a split, the pane that takes your typing has an accent border and the others fade slightly.
- The bars behave as a Mac title bar: drag them to move the window, double-click to zoom (following
  Desktop & Dock's setting). A click on the empty tab row no longer opens a tab; "+" and ⌘T do.
- Show and hide each part of the window, remembered across launches: the meadow (⌃⌘S), Files and Changes
  (⇧⌘E, ⇧⌘C), and the status bar (⌥⌘/), from the View menu, the buttons in the top bar and the palette;
  View › Reset Layout puts everything back. Drag the side panel's edge past its least width to close it;
  double-click a divider for its usual width, or to share the room evenly between two panes. A zoomed
  pane (⇧⌘↩) says so and brings the others back with a click. Sections in Changes fold away.
- A click on a tab, a divider or the bars works the first time while Whiskr is in the background, as in
  Safari; it used to be spent bringing the window forward.
- ⌃⌘F enters full screen again (AppKit's own Enter Full Screen item had hidden ours, and with it the key).
- Tabs answer every click: a click on a tab's close button or title, with the pointer resting there, was
  taken by the drawing over it and did nothing, so tabs could not be closed by their ×.
- Opening, closing and switching tabs take effect in the frame you act in: the new tab's terminal has the
  keyboard at once (keys typed straight after ⌘T or ⌘W reach it, never the tab before), its shell starts
  without waiting, and a closed tab leaves the row without a fade.
- Terminals draw with Metal on a thread of their own, so neither the meadow nor the window's own work
  holds up a terminal's frames, and the meadow draws more gently while you type. Output arrives in fewer,
  larger pieces, and hidden parts of the window (Home, the workspace list) no longer recompute as tabs
  change.
- `make run` builds and opens the optimised app; `make run-debug` the Debug build. `make perf` measures
  typing, tabs and output as a visible window shows them, in an invisible run.
- English and Japanese throughout, following the system language.
- Upgrading from the app's earlier working name, "Workers Factory": at first launch, its settings, saved
  layout, the Claudes' last state and themes are carried over. Its git worktree folder
  (`~/.workers-factory`) becomes `~/.whiskr` when it holds no checkout; checkouts stay where they are. A
  session host the old app left running is never stopped, and its terminals are counted and left alone.
