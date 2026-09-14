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
- Files and Changes beside the terminals. A light editor with find and replace and Go to Line. Markdown, image and PDF previews. Diffs side by side or inline. Staging,
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
- Find in a terminal (⌘F): the app's own bar at the terminal's top right, with "3 of 12", ⌘G and ⇧⌘G
  (Return and ⇧Return), ⌘E for the selection, and Esc to give the keyboard back.
- Command marks for zsh, bash and fish (OSC 133; quiet when your prompt or iTerm2's integration writes
  them): Edit › Previous Command and Next Command (⌘↑, ⌘↓) and Select Previous Output and Select Next
  Output (⇧⌘↑, ⇧⌘↓) in terminals. A plain terminal's lantern turns red when its last command failed and
  you have not seen it.
- ⌘ over a path or a web link in a terminal underlines it; ⌘-click opens it, a file at its line
  (`x.ts:12:3`, `x.ts(12,3)`, `"x.py", line 12`, quoted paths, git's `a/` and `b/`).
- A terminal's right-click menu: Copy, Paste, Select All, Find…, Clear, Split Right, Split Down and Zoom
  Pane, with Open, Reveal in Files and Copy Path (or Open Link and Copy Link) over a link. It selects
  the word under the pointer first. ⌥-right-click reaches it in a full-screen program that takes clicks.
- Go to (⌘P) takes `>` for commands, `:42` for a line of the file shown and `name:42` for a file at a
  line; every word must match, quotes match as written, and the closer match ranks first.
- ⌃Tab by most recent use: a tap flips back to the tab before; held, a small list of tabs.
- Drag a tab onto the edge of a pane to split there, or onto its middle to move it into that pane's tab.
- Dividers light in the accent colour when the pointer rests on them or drags them; a double-click resets
  them.
- A hollow cursor in terminals without the keyboard, and a bell on the tab of a terminal that rang out of
  sight.
- Tab titles follow the program in front (after 0.4 s, so `ls` does not flicker) or the folder, in zsh,
  bash and fish; a Claude's tab shows Claude's own title.
- Files selects the file of the tab shown, and shows chains of single folders as one row
  (`src/main/java`).
- Diffs fold unchanged lines ("⋯ 120 unchanged lines", a click opens them), and each change can be
  reverted (undoably), staged or unstaged on its own.
- Increase Contrast also strengthens secondary text, the focused pane's border and the selected tab's
  line; Full Keyboard Access moves through the window's regions in order.
- No dialog at launch: terminals still running in another version's session host are a quiet bar on
  Home. Notes that need no answer go by themselves after about 10 seconds in sight, never while the
  pointer is on them.
- Whiskr › Secure Keyboard Entry.
- View › Animate Meadow (also in Settings › Meadow): off, the meadow holds still and cats change only
  as Claude does. It follows Reduce Motion until you choose.
- A crowded blanket keeps its lanterns in one row of at most eight; the rest are counted on its flag.
- Code coloured by the TextMate grammars VS Code uses, for about 45 languages (Swift, TypeScript and TSX,
  JavaScript and JSX, Python, Rust, Go, C, C++, Objective-C, Java, Kotlin, Ruby, PHP, C#, HTML, CSS, SCSS,
  Less, JSON, YAML, TOML, Markdown with code blocks in their language, shell, SQL, Dockerfile, Makefile, XML,
  Lua, Dart, Zig, GraphQL, diff, ini, git commit and rebase messages, logs and more), each file's language
  found as VS Code finds it. The same colours in Markdown previews and diffs. Colouring happens off the
  main thread, so typing in a 50,000-line file stays smooth, and a file opens already in its colours;
  lines over 20,000 characters are left uncoloured, as in VS Code, and a line over 80,000 (a minified
  file's) is read-only, with a bar offering Edit Anyway, so a key never stalls the window. The status bar's
  language is a menu, to colour a file as another language.
- VS Code colour themes: Settings › Terminal › Add Theme… (or a drop on the theme list, or File › Import
  Themes and Languages…) takes a theme file, an extension folder or a `.vsix`, and code is then coloured
  exactly as in VS Code. A theme's light and dark versions become one theme; two themes can be paired by
  hand. Colours too faint for Whiskr's layers are strengthened just enough. New built-in themes: Modern
  (VS Code's Light and Dark Modern) and Monokai, and Solarized now colours code as VS Code's Solarized.
  Languages and grammars can be added the same way; nothing in an extension is ever run.
- Settings › General › Import Settings reads your VS Code or Cursor settings once, when you ask (fonts,
  indentation, wrapping, invisibles, saving, the terminal's cursor and the colour theme), and says what it
  applied.
- File icons people know from VS Code (Seti) in Files, tabs, Go to and Changes, in one colour.
- VS Code's keys where they suit a Mac: ⌘B hides the meadow, ⌘\ splits, ⇧⌘V previews Markdown, and in the
  editor ⌥↑ ⌥↓ move lines, ⇧⌥↑ ⇧⌥↓ copy them, ⇧⌘K deletes them, ⇧⌘\ goes to the matching bracket, ⌥Z
  wraps lines and ⌃G goes to a line. File › Save All (⌥⌘S). Terminals still receive these keys.
- The editor closes brackets and quotes as VS Code does (and types over them, and wraps a selection), boxes
  the matching bracket, shows indent guides and tints other occurrences of the word at the cursor.
  Settings › Editor: indent with spaces or tabs, and trim trailing whitespace and insert a final newline on
  save. A repository's `.editorconfig` is followed.
- English and Japanese throughout, following the system language.
- Upgrading from the app's earlier working name, "Workers Factory": at first launch, its settings, saved
  layout, the Claudes' last state and themes are carried over. Its git worktree folder
  (`~/.workers-factory`) becomes `~/.whiskr` when it holds no checkout; checkouts stay where they are. A
  session host the old app left running is never stopped, and its terminals are counted and left alone.

### Fixed

- A minified file opens faster: its one long line was laid out twice.
- ⌘↑ and ⌘↓ move to the start and end in the editor and open in Files again (the terminal's command keys had
  taken them everywhere).
- Typing in a file with one very long line (minified code) no longer waits for its colours.
- A long file reloaded from the disk while scrolled could quit the app.
- The meadow button and ⌃⌘S show the meadow in narrow windows too (they did nothing below about 880 pt).
- A narrow tab row no longer runs under "+", and one tab no longer shows an empty tab list.
- Every button in the bars acts on the first click in a window behind others, as the tabs did.
- The palette no longer greys the window as if it had lost focus.
- ⌘↩ commits only from the commit message; ⌘. is Cancel wherever text is typed.
- Programs can no longer read the clipboard through the terminal (OSC 52 reads are refused).
- Much less memory with many tabs open: a terminal you have not looked at for 30 seconds gives back its
  graphics memory (20 tabs: about 200 MB instead of 770 MB).
- The first terminal after an install or update opens without waiting for its shaders to compile.
- Pasting a large text no longer freezes the window while the session host is busy.
- A link a terminal printed with a scheme other than http, https, mailto or file asks before it opens,
  showing where it really leads.
- Discard, Stage and Unstage treat file names literally (`app/[id]/page.tsx` no longer matches other files).
- Double-clicking the meadow's edge puts it back at its usual width.
- The theme editor drops the Sidebar, Hover and Pressed colours, which had no effect.
