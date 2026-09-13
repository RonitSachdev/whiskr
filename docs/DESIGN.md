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
  meadow steps aside. View offers Meadow and Terminals, Terminals Only, Meadow Only, Hide Meadow, and
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
- **Closing** asks nothing. ⌘Z brings back what was closed, with its process, for ten seconds, and ⇧⌘T
  reopens it later. Closing a workspace's last tab closes the workspace; closing the workspace on screen
  returns Home, never into another workspace's terminal. Closing a workspace asks only when Claude or
  another program is running in it.
- **Quitting** leaves every terminal running in the session host. ⌥⌘Q (Quit and Stop All Terminals) asks
  only when something is running.

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
  when the last command failed and you have not seen it.
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
- **The answer card.** Clicking a requesting cat whose terminal is not on screen opens a card beside the
  meadow, never over it: 1 Allow, 2 Deny, Go to Terminal (⌘↩). It is armed after 400 ms. It sends the key
  only if the same request is still open and the terminal's last lines have not changed.
- **The edge capsule.** A blanket with a request that is scrolled out of view shows as "↑ 1 need you" at
  the meadow's edge.

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
never a dialog. Syntax colours come from our own small line lexer, not a dependency per language.

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
  pin when it has them. Nothing else is written in the scene.
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

### Where the keys go

- **The selected tab** is the content's colour and opens into its panes (no line under it), with a 2 pt
  accent line along its top: two signs, as VS Code's. Unselected tabs are the chrome's colour with
  secondary text.
- **The focused pane of a split** has a 1.5 pt accent border; the others fade 10 % toward the background.
  A pane alone shows neither.
- **When the window is not the one in use,** the accent turns grey (`lineStrong`) and the bars' content
  goes quieter, as every Mac title bar does.

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
- **Icons:** SF Symbols, 13 pt regular in the bars, 11 pt in tabs, headers and the status bar.

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
  closes and Home comes.

### Elsewhere

Mac conventions throughout: every command in the menus with its key, standard Settings (⌘,) with
categories on the left and one setting per row on the right, and standard Save / Don't Save / Cancel.
English and Japanese, following the system language, for everything a person reads: menus, settings,
notifications, Help, and the words in the scene.

## The app icon

`docs/logo.svg` is the source of the app icon (`make icon` renders the asset catalogue from it): a black
cat peeking up from the bottom of a warm off-white tile, with ring eyes and small ears at its corners. No
neck, no tail, no mouth, no whiskers. It is the project's own cat. It is not a licence to use it as a mark;
see the README's licence section.
