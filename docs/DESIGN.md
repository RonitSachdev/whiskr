# Design

What Whiskr is, how it behaves, and how it looks. These are decisions, not suggestions: a change that goes
against one should change this page in the same pull request and say why. For how it is built, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## What it is

1. Whiskr is a **terminal app**. Each workspace is a folder you work in, with tabs of real terminals that
   you can split into panes.
2. Where a terminal multiplexer has its sidebar, Whiskr has a small **meadow**: one picnic blanket per
   workspace. Wherever `claude` runs, a black cat sits on that workspace's blanket and acts out what Claude
   is doing. Small cats beside it are its helpers.
3. **You never manage cats.** You work in terminals, glance left to see who needs you, and press ⌘J to go
   there.

It is a standalone, single-Mac app for Claude Code. It does not start Claude for you: you type `claude`
yourself, in any pane, and the app notices.

### What it deliberately leaves out

- Forms for starting a session (account, model, first message). A new workspace or tab is just a shell.
- A chat, task or timeline view beside a terminal. The terminal already shows the conversation; one view
  per thing.
- An IDE. The editor is a light one: no autocomplete, no language servers.
- Remote machines and a phone app.
- In-app key rebinding. macOS already lets anyone rebind any menu item.

## Words

One word for each thing, the same in menus, tooltips, notifications, accessibility labels and Help.

| Thing | Word | Japanese | Never shown as |
|---|---|---|---|
| A folder you work in, with its tabs | **Workspace** | ワークスペース | space, project, session, blanket |
| A terminal tab | **Tab** | タブ | blanket, surface |
| A split region inside a tab | **Pane** | ペイン | split, window |
| A Claude Code process in a pane | **Claude** | Claude | agent, session, cat, bot |
| One of Claude's subagents | **Helper** | ヘルパー | subagent, small cat, child |
| A permission request, question or plan waiting on you | **Request** | リクエスト | prompt, blocker, alert |
| A turn that finished while you weren't looking | **Finished** | 完了 | done, idle, complete |

"Blanket", "cat", "lantern", "meadow" and "flag" are pictures, never labels. Only the Help page that
explains the pictures uses them. "Session" is never shown, because people hear it as Claude Code's own
sessions.

## The window

- **One window, framed.** A **top bar** runs the window's full width (the traffic lights, the meadow
  button and Home; in the middle a search field, "Go to a workspace, tab or file ⌘P", which opens Go to;
  "+", the Files and Changes button and Settings at the end), and a **status bar** runs along its foot
  (branch, folder as `~/…/parent/folder`, how many Claudes and how many need you, the focused file's
  details, ⌘P and ⇧⌘P). Both are drawn by the app in the chrome colour, never as toolbar items. Between
  them the meadow is on the left and the work area on the right: a **tab row** led by the **workspace
  button** (its colour, its name, a chevron: the menu of every workspace), then the panes. Terminals have
  no header; a file or a diff has a slim one with its path. Nothing in the bars repeats what is on
  screen elsewhere.
- **Sizes.** By default the meadow takes about 42 % of the window and the terminals keep at least 80
  columns. The divider drags from a 240 pt sidebar to the meadow alone. Below about 880 pt of window, the
  meadow steps aside; showing it then (⌃⌘S, the meadow button) gives it its narrowest sidebar beside the
  terminals, at any window size the app allows. View offers Meadow and Terminals, Terminals Only, Meadow Only, Hide Meadow, and
  Show Workspaces as List.
- **The bars behave as a title bar.** The top bar's empty stretches and the tab row's move the window,
  and a double-click on them does what Desktop & Dock says a title bar's double-click does (zoom, unless
  set to minimise or nothing). Nothing there opens a tab: new tabs come only from "+", ⌘T and the menus.
- **Showing and hiding, as in VS Code.** Every region but the tab row can be put away and brought back
  from the same places, and the choice is remembered: the meadow (⌃⌘S, the sidebar button by the
  traffic lights), Files and Changes (⇧⌘E and ⇧⌘C, the panel button at the top right; per workspace),
  and the status bar (View › Hide Status Bar, ⌥⌘/, since ⌘/ comments in the editor). Toggle buttons show
  their state with the selected fill. The tab row stays: it holds the workspace button and "+". Dragging
  a divider past its region's least width closes it (the same drag coming back opens it); a double-click
  on a divider gives the usual width (the meadow's, the panel's) or shares the room evenly (between
  panes). Hiding a region with the keyboard in it hands the keyboard to the region that stays. View ›
  Reset Layout brings every region back at its usual size. Zoom Pane (⇧⌘↩, also in a split tab's menu)
  fills the tab with one pane; a note at its corner, "Zoomed · Show All Panes", brings the others back.
  In Changes, Staged, Changes and Untracked fold under their chevrons, remembered.
- **The window title** is the workspace's name (for the Window menu and Mission Control), "Whiskr" on
  Home. It is never "Claude".
- **Workspaces** are named after their repository (else their folder) and follow the first terminal's
  `cd` until renamed. Choosing a workspace yourself scrolls its blanket into view.
- **Home** is a place, not a tab: no workspace selected. The meadow shows every blanket with none ringed,
  and the work area shows the Home page: the app's cat, one line on where cats come from, Open Folder…
  (⌘O), New Terminal (↩), **Open** (the workspaces open now, in the meadow's order, each with its colour,
  name, branch, state and Claude count; Return takes you back in exactly where you left it) and
  **Recent** (folders not already open). The tab row shows "Home" and no tabs. It looks the same with no
  workspace or many. **Every launch lands on Home**; everything comes back running, one click away.
  Go › Home is ⇧⌘H; it is also the house in the top bar and first in the workspace button's menu, and
  ⌘N (New Workspace) goes there.
- **Nothing at launch asks.** Terminals still running in another version's session host, and the Claudes
  not resumed because of them, are a quiet bar on Home with Details and a close button, never a dialog.
- **Go to (⌘P)** reads its field as VS Code's Quick Open does: a name finds workspaces, tabs, Claudes and
  files; `>` turns it into the command list; `:42` goes to a line of the file shown; `name:42` opens a
  file at a line. Every space-separated word must match, and a quoted word matches as written. A match
  just after `/` beats one after `-` or `.`, and among names that start with what you typed, the shorter
  wins.
- **Closing** asks nothing. ⌘Z brings back what was closed, with its process, for ten seconds, and ⇧⌘T
  reopens it later. Closing a workspace's last tab closes the workspace; closing the workspace on screen
  returns Home, never into another workspace's terminal. Closing a workspace asks only when Claude or
  another program is running in it.
- **Quitting** leaves every terminal running in the session host. ⌥⌘Q (Quit and Stop All Terminals) asks
  only when something is running.

## Terminals

- **Find (⌘F)** is the app's own bar at the terminal's top right: the field, "3 of 12", previous and
  next, close. ⌘G and ⇧⌘G (Return and ⇧Return in the field) step, ⌘E finds the selection, and Esc
  closes the bar and gives the keyboard back to the terminal.
- **Commands.** The shell integration marks each prompt and each command's end with its exit status
  (OSC 133), unless your prompt or hooks mark them already. Edit › Previous Command (⌘↑) and Next Command
  (⌘↓) scroll from prompt to prompt; Select Previous Output (⇧⌘↑) and Select Next Output (⇧⌘↓) select
  what a command printed. They work in a terminal only: the editor keeps ⌘↑ and ⌘↓.
- **Links.** With ⌘ held, a web link or a path that exists is underlined, and ⌘-click opens it: a file
  at its line, in the editor. Paths are read as compilers, test runners and `grep -n` print them
  (`x.ts:12:3`, `x.ts(12,3)`, `"x.py", line 12`), in quotes when they hold spaces, with git's `a/` and
  `b/` taken off, relative to the pane's folder.
- **Right-click** selects the word under the pointer when nothing is selected, then offers Copy, Paste,
  Select All, Find…, Clear, Split Right, Split Down and Zoom Pane. Over a path it starts with Open,
  Reveal in Files and Copy Path; over a web link, Open Link and Copy Link. A program that asked for mouse
  clicks (a full-screen one) gets the right-click instead, unless Option is held.
- **The cursor** is hollow in a terminal that does not have the keyboard.
- **Whiskr › Secure Keyboard Entry**, as Terminal has it: a checkmark, remembered, and let go while the
  app is not in front, as the system asks.

## States, and how they look

Each state differs by **silhouette**, **mark**, **colour** (on the mark only, never the cat) and
**motion**. Silhouette plus mark alone must be enough to read it, so nobody depends on colour.

| State | Silhouette | Mark | Colour | Motion |
|---|---|---|---|---|
| **Request** | Standing on hind legs, facing you, one paw raised | "!" bubble | Vermillion `#D55E00` | One hop when it starts, repeated at 2 and 10 minutes, then still. Never a continuous pulse |
| **Error** (turn ended on an error) | Sitting, facing you, ears back | "×" bubble | Vermillion | One hop, then still |
| **Finished** (not yet seen) | Sitting upright, tail wrapped | "✓" bubble | Blue `#0072B2` | None |
| **Working** | Head down at a prop within paw's reach: book (reading), laptop (editing), lever (running), magnifier (searching), chin on paw (thinking), sorting (tidying), watching helpers (supervising) | None | None | A small anchored loop; never travels across the meadow |
| **Idle** (seen) | A loaf | None | None | Breathing |
| **Napping** (idle over 10 minutes) | Curled | A small "z" | Grey | As idle |

- **Finished until seen.** A finished turn keeps its "✓" until its pane has been on screen for a second.
- **The same marks everywhere.** Tabs, the workspace button, Go to and the Dock use the same marks.
  Request and error: a vermillion circle with a white glyph. Finished: a blue dot. A tab shows the most
  urgent mark of its panes, and helpers' requests roll up to their boss's tab.
- **Plain terminals** are lanterns, drawn only after dark: lit while a command runs, dark when idle, red
  when the last command failed and you have not seen it (seen: its pane on screen for a second in the
  window in use). The lanterns stand in one tidy row along the blanket's front edge, at
  most eight, failed first, then lit, then dark. More are counted on the flag as a small lantern and
  "+N", red when one counted has failed.
- **Faces stay toward the camera.** Every waking cat's face stays within 40° of the camera, whatever it
  is doing, so a working cat never reads as a dark lump.
- **Contrast.** Every bubble against the grass, and the black cat by day and by night, reaches 3:1 (WCAG
  1.4.11). At night each picnic's fireflies give the cats a warm rim of light.

## Attention

- **Nothing an agent does may take control.** No event may activate the app, raise or move the window,
  switch workspace, tab or pane, move keyboard focus, scroll the meadow, move the camera or open a
  popover. Only the user's own actions do those.
- **⌘J (Next Request)** goes to the oldest request, then the oldest finished turn, then back where you
  were.
- **Sounds:** three soft, generated sounds: two rising notes for a request, two low notes for an error, one
  soft knock for a finish. At most one every two seconds, the most important first, after a pause in
  typing. Only while you are in the app and not typing in that Claude's pane.
- **Notifications** only while you are in another app: requests (after a 2-second re-check), and finished
  turns that took 30 seconds or more. Permission requests carry Allow and Deny.
- **Dock:** a badge counting requests, and a Dock menu listing who is waiting. **Pause Alerts** silences
  sounds and notifications for a while.
- **The bell.** A plain terminal that rings its bell out of sight puts a bell on its tab until you have
  seen the pane. The bell is heard (the system beep) only when its pane is in sight and alerts are not
  paused. Claude's tabs keep their own marks.
- **The answer card.** Clicking a requesting cat whose terminal is not on screen opens a card beside the
  meadow, never over it: 1 Allow, 2 Deny, Go to Terminal (⌘↩). It is armed after 400 ms. It sends the key
  only if the same request is still open and the terminal's last lines have not changed.
- **The edge capsule.** A blanket with a request that is scrolled out of view shows as "↑ 1 need you" at
  the meadow's edge.

### Notes

A note the app puts up by itself (a bar, a toast) follows these rules:

- It never asks first and never blocks: no dialog, nothing over the work.
- It stays only while a decision is needed from you (Reload or Keep Mine).
- Otherwise it goes about 10 seconds after it was first seen. Its time counts only while the window is
  the one in use and the pointer is not on it, so it is never taken away while you read it. Its close
  button puts it away sooner.
- "Closed · Undo ⌘Z" is one: its undo waits while the pointer is on it.

## The story view

A helper, or a Claude started outside the app, has no terminal of its own to show. In its place is its
story: one read-only column in time order. The task comes first. Then what it said, as plain text, with
the steps between two messages folded into one quiet line ("Read 3 files · ran 2 commands · 14s") that
opens to the steps. A failed step is never folded away. The report comes last, set apart, and a live line
at the bottom says what it is doing now. The view follows the newest line only while you are at the
bottom.

## Files, editor and changes

One side panel on the terminal region's trailing edge holds **Files** (the workspace's repository as an
outline, with git letters) or **Changes** (staged, changed and untracked, with a commit box). Files and
diffs open as tabs in the same tab row, so they can sit in a split beside a terminal. A click opens a
preview tab that the next click reuses; editing or double-clicking keeps it. Claude edits files all the
time: an unmodified file reloads silently, and a modified one shows a quiet bar (Reload or Keep Mine),
never a dialog.

- **VS Code's data, Whiskr's own window.** People bring their habits from VS Code and Cursor, so Whiskr
  reads what those editors are made of where it is data or convention, and stays native: no web view, no
  Monaco, no extension runs. Code is coloured by the **TextMate grammars VS Code ships** (about 45
  languages, detected by file name, extension and first line as VS Code does) in the **theme's own token
  colours**, so an imported VS Code theme colours code exactly as it does there; Whiskr's own and terminal
  themes colour code from their sixteen terminal colours. **VS Code colour themes** import from a file, a
  `.vsix` or an extension folder (Settings › Terminal › Add Theme…, a drop on the theme list, or File ›
  Import Themes and Languages…), as do grammars. Files show **Seti's file icons**, the ones VS Code shows by
  default. Settings › General can **read VS Code's or Cursor's settings once**, when asked (fonts, tab
  size, wrapping, saving, the theme), and says what it applied. Nothing is ever read before a click, and
  nothing is sent anywhere.
- **The editor's conveniences are VS Code's,** with its rules: brackets and quotes close themselves and
  are typed over, a selection is surrounded by a typed bracket or quote, the bracket matching the one at
  the cursor is boxed, indent guides show each level (the cursor's block stronger), other occurrences of
  the word under the cursor are tinted, lines move (⌥↑ ⌥↓), copy (⇧⌥↑ ⇧⌥↓) and delete (⇧⌘K). Saving may
  trim trailing whitespace and add a final newline (Settings › Editor, off as in VS Code). A repository's
  **`.editorconfig`** decides indentation, line endings, encoding and those two for its files. No
  multiple cursors: NSTextView types into one place, and doing it properly means owning every editing
  command.
- **Lines too long for an editor** are treated as VS Code treats large files: past 20,000 characters a
  line is not coloured, and past 80,000 (a minified file's) it is read-only, with a bar that says so and
  offers Edit Anyway, because every key in it would take a visible moment. The rest of the file edits as
  usual.
- **The status bar's language** is a menu: a file can be coloured as another language (Auto Detect goes
  back), for as long as the app runs.

- **Files follows the tab shown.** As tabs change, the file of the tab shown is selected and scrolled
  into sight; the keyboard stays where it was.
- **Compact folders.** A chain of folders that each hold one folder shows as one row, `src/main/java`.
  Renaming it edits the part you change; a new file goes into the last folder.
- **Diffs fold what did not change.** Each unchanged stretch is one row, "⋯ 120 unchanged lines", and a
  click opens it. Next and previous change skip the folds.
- **One change at a time.** Under the pointer, each change offers Revert Change and Stage Change
  (Unstage Change in a staged diff), applied to exactly that change with `git apply`, off the main
  thread. Revert can be undone: Edit › Undo Revert Change, or Undo in the note it leaves.

## The meadow and the cats: look rules

Keep these when adding poses, props or scenery. They are what makes the meadow Whiskr's.

### The cat

- **A black blob cat**, sculpted as one continuous, smooth, matte clay skin. Not assembled from basic
  shapes. Small rounded ears, not pointy ones.
- **Always black.** Coloured coats were tried and rejected. Variety, if it ever comes, stays in dark tones.
- **No mouth, ever, in any state.** The face is two wide white ring eyes.
- **Paws are short, fixed nubs** that only change direction. They never stretch, grow, appear or
  disappear. With nothing to hold they hang against the belly. A prop must sit within reach; never stretch
  a paw to it.
- **Scale.** One unit is about 13 cm and the cat is 2.3 units tall. Grass reaches its belly, flowers
  stand about head height with eye-sized blooms, and trees tower.
- **Helpers** are smaller cats. They sit beside and behind their boss and turn toward it. When a task is
  handed over, a speech-bubble note passes between them. A helper trots back to report.

### The meadow

- **Same clay style as the cat** for everything: blankets, props, plants, trees, stones. Smooth and matte,
  not faceted low-poly.
- **One gingham picnic blanket per workspace**, each its own colour, with clear grass between blankets.
  Nothing overlaps anything. A worktree's blanket lies beside its repository's, joined by flat clay
  stepping stones.
- **A small name flag** stands behind each blanket: a colour dot, the workspace's name, and its branch and
  pin when it has them, and after dark the "+N" of lanterns that did not fit. Nothing else is written in
  the scene.
- **Plants are modelled on real ones**, then simplified into clay. They grow in clumps and groups, never an
  even sprinkle. No shrubs and no dandelion clocks.
- **Props are real objects.** The picnic is a closed, classic wicker hamper, not blobs. Picnic things are a
  setting (nothing, just the hamper, or the hamper and a few things), laid out tidily beside the hamper,
  never scattered.
- **Night is properly dark**, with fireflies gathered at the picnics casting warm yellow light. Lanterns
  appear only at night.
- **No streams or rivers.** That picture is kept for a second machine, which this app does not have.

### Motion

- Every cute reaction (a cat arriving or trotting off, a butterfly landing on a napper, a glance at the
  pointer) is anchored to its spot, lasts 2 seconds or less, and never plays on a cat with a request.
- Nothing cute in the top bar, tab row, status bar, panes, menus, notifications, the answer card or the
  palette.
- While you type, ambient reactions wait and only state changes animate. With Reduce Motion, hops, walks
  and camera moves become short cross-fades.
- **Animate Meadow** (View, and Settings › Meadow › "Animate the meadow"; WCAG 2.2.2). Off, the grass,
  butterflies, fireflies and the cats' fidgets hold still; state changes still show, as cross-fades, and
  a still meadow draws nothing between changes. Until you choose, it follows Reduce Motion.
- The camera never moves on its own. A drag turns the view, ⌘-drag slides it, and scroll or pinch zooms
  toward the pointer. In a narrow sidebar, scrolling scrolls the column of blankets.

## Look of the interface

Neutral and solid, framed like a professional editor (Cursor, VS Code, Xcode): flat surfaces, charcoal
text, lines between regions, shadows only on what floats. No translucent panels, no glass in the work
area, and no cream-and-brown palette. Every colour comes from the theme (`AppColorKey`); every measure
from `Look` (`UI/Theme.swift`).

### Layers

The window has two layers and one line, so its structure shows at a glance in light and dark and in
every theme:

| Layer | What | Colour |
|---|---|---|
| **Content** | Panes (terminals, editors, diffs), Home, and the selected tab | The terminal's background |
| **Chrome** | Top bar, tab row (and its unselected tabs), status bar, Files and Changes panel | `chrome`: a step below the content (toward the text in light themes, toward black in dark ones), 1.03–1.25:1 against it |
| **Line** | Between any two regions: under the top bar, along the tab row's foot, after each tab, above the status bar, at the meadow's edge, between panes, before the side panel | `line`: at least 1.3:1 on both layers; 3:1 with Increase Contrast |

The meadow is its own region, full height between the bars, edged by a line; nothing of the chrome is
tinted toward its green. Colour in the chrome means state, never decoration.

**Dividers** show they can be dragged as VS Code's do: once the pointer has rested on one for 300 ms
(passing over shows nothing), it turns the accent colour, 3 pt wide, and stays so while dragged. The
resize cursor comes at once. This holds for every divider: the meadow's edge, between panes, the side
panel's edge.

**Increase Contrast:** lines go to 3:1, secondary and tertiary text step up one level, the focused
pane's border is 2.5 pt and the selected tab's line 3 pt. A theme that forces light or dark keeps it.

### Where the keys go

- **The selected tab** is the content's colour and opens into its panes (no line under it), with a 2 pt
  accent line along its top: two signs, as VS Code's. Unselected tabs are the chrome's colour with
  secondary text.
- **The focused pane of a split** has a 1.5 pt accent border; the others fade 10 % toward the background.
  A pane alone shows neither.
- **When the window is not the one in use** (neither main nor key: the palette, a panel of its own, does
  not count), the accent turns grey (`lineStrong`) and the bars' content goes quieter, as every Mac title
  bar does. Hover and pressed fills are the primary colour at fixed strengths, not theme colours.
- **Keys from VS Code where they are free.** ⌘B hides the meadow (the side bar's key), ⌘\ splits, ⌥Z
  wraps lines, ⇧⌘V previews Markdown, ⌥⌘S saves all, ⌃G goes to a line, and the line keys above, each a
  second key beside the Mac one where both exist. A key without ⌘ belongs to the editor only while it has
  the keyboard; in a terminal it goes to the program, so ⌥ stays Meta and ⌃ keys reach the shell. Keys
  that would take a terminal's key or fight a Mac convention are not taken (⌃\`, ⌘1–3 for groups, ⌥⌘
  arrows, ⌘J for the panel). `KeyTable` in the Kit lists every key and a test checks that no two collide.
- **The keyboard is always visible.** The rename field in Files shows the system focus ring. With Full
  Keyboard Access, Tab goes top bar → tab row → content → side panel → status bar.

Panes meet flush with a line between them (as Xcode and VS Code), not as cards with gaps: the selected
tab must join its panes, and the meadow beside them is already the window's one picture.

### Measures

- **Spacing:** 4, 8, 12, 16, 24, 32 (2 and 6 inside a control).
- **Radii:** 4 for small things (key caps, badges), 6 for controls (buttons, fields, rows), 10 for what
  floats (palette, cards, popovers). Bars, tabs and panes are square: they meet edge to edge.
- **Heights:** top bar 40 (the compact title bar's band: the traffic lights sit centred in it), tab row
  34, file header 30, status bar 24; controls in the bars 26 tall, icon buttons 28 wide.
- **Type:** tab titles 13 (medium when selected), the top bar's field 12, status bar, panel headers and
  breadcrumbs 11, Home's title 22. Nothing under 10.
- **Icons:** SF Symbols, 13 pt regular in the bars, 11 pt in tabs, headers and the status bar. Files
  (in Files, tabs, Go to, Changes and the file's header) show Seti's glyphs, the file icons VS Code shows by
  default, at the same sizes and in one colour, the text's: colour in the chrome means state, and git
  letters already carry it. Folders keep SF Symbols (Seti has none).

### States

Every control in the bars has the same hover (the primary colour at 6 %), pressed (11 %) and selected
(9 %) fills, and a tooltip naming it with its key. Disabled controls are at 40 %. The search field is the
content's colour inset in the chrome, its line darker under the pointer.

### Tabs

- Tabs share the row equally up to 220 pt. When even 128 pt each will not fit them all, the row shows as
  many as fit, a run of neighbours that always holds the selected tab whole (it moves only when the
  selected tab would leave it), and a chevron with how many are out of sight, whose menu lists every
  tab. The row never scrolls: every tab in sight is whole, its close button in reach. "+" always stays
  at the row's end. New tabs come only from "+", ⌘T and the menus: the row's empty stretch belongs to the
  window, as the top bar's does.
- Each tab shows what it is (a terminal, a file, changes; a Claude's request or finished mark in its
  place), its title, and a close button at its **trailing** end, as in Cursor, VS Code and Zed: always on
  the selected tab, on the others under the pointer; an unsaved file shows a dot there until the pointer
  comes. A middle click closes. On a workspace's only tab the close button's tooltip says the workspace
  closes and Home comes. A plain terminal that rang its bell out of sight shows a bell in place of its
  icon until seen.
- **Titles.** A plain shell's tab shows the program in front once it has been there 0.4 s (so `ls` does
  not flicker), else the last part of its folder, following `cd`. A Claude's tab shows Claude's own
  terminal title. A renamed tab keeps its name. Titles from programs are taken at most 4 times a second.
- **⌃Tab goes by most recent use,** as in VS Code and Safari. A tap flips to the tab shown before. Held,
  ⌃ shows a small list of the workspace's tabs after 0.2 s: Tab, ⇧Tab, ↑ and ↓ move, letting go of ⌃
  opens the one chosen, Esc stays. Any other key opens the chosen tab and goes to it, so no key is lost.
- **Drag a tab onto a pane to split it.** Dropped on a pane's outer tenth (right, left, top or bottom),
  it splits there, with a tinted half showing where it will go; dropped in the middle, it moves into
  that pane's tab. Terminals, files and diffs alike. Esc cancels.

### Elsewhere

Mac conventions throughout: every command in the menus with its key, standard Settings (⌘,) with
categories on the left and one setting per row on the right, and standard Save / Don't Save / Cancel.
English and Japanese, following the system language, for everything a person reads: menus, settings,
notifications, Help, and the words in the scene. ⌘. interrupts the focused terminal; wherever text is
typed (a rename, the commit message, Go to, a card) it is the Mac's Cancel. ⌥⌘W closes the tab and ⌘W a
pane, as in iTerm2. ⌘↩ commits only from the commit message. Every control in the bars acts on the first
click, even in a window behind others, as the tabs do. A program never reads the clipboard (OSC 52 reads
are refused; writes, which tmux and editors use, still work).

## The app icon

`docs/logo.svg` is the source of the app icon (`make icon` renders the asset catalogue from it): a black
cat peeking up from the bottom of a warm off-white tile, with ring eyes and small ears at its corners. No
neck, no tail, no mouth, no whiskers. It is the project's own cat. It is not a licence to use it as a mark;
see the README's licence section.
