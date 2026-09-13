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
- A window frame like a professional editor's: a top bar across the window (meadow button, a field that
  opens Go to, New, Files and Changes, Settings) and a status bar along its foot (branch, folder, Claudes
  and requests, the editor's details, ⌘P and ⇧⌘P), with the meadow and the work area between them.
- English and Japanese throughout, following the system language.
- Upgrading from the app's earlier working name, "Workers Factory": at first launch, its settings, saved
  layout, the Claudes' last state and themes are carried over. Its git worktree folder
  (`~/.workers-factory`) becomes `~/.whiskr` when it holds no checkout; checkouts stay where they are. A
  session host the old app left running is never stopped, and its terminals are counted and left alone.
