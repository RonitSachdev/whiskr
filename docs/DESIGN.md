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

- **One window.** The meadow is on the left, flush to the window's edges and up under the title bar. The
  terminals are on the right. The terminal region's top row is the tab bar (in the terminal's own colours,
  so tabs and terminal read as one surface), led by the **workspace button**. Panes have no headers. A
  quiet status line sits at the bottom: folder, branch, how many Claudes need you, ⌘P and ⇧⌘P.
- **Sizes.** By default the meadow takes about 42 % of the window and the terminals keep at least 80
  columns. The divider drags from a 240 pt sidebar to the meadow alone. Below about 880 pt of window, the
  meadow steps aside. View offers Meadow and Terminals, Terminals Only, Meadow Only, Hide Meadow, and
  Show Workspaces as List.
- **The window title** is the workspace's name (for the Window menu and Mission Control). It is never
  "Claude".
- **Workspaces** are named after their repository (else their folder) and follow the first terminal's
  `cd` until renamed. Choosing a workspace yourself scrolls its blanket into view.
- **The Start page.** ⌘N opens a workspace on a Start page: Open Folder…, New Terminal, recent folders.
  On launch everything comes back, and the Start page shows only when nothing does.
- **Closing** asks nothing. ⌘Z brings back what was closed, with its process, for ten seconds, and ⇧⌘T
  reopens it later. Closing a workspace asks only when Claude or another program is running in it.
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
diffs open as tabs in the same tab bar, so they can sit in a split beside a terminal. A click opens a
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
- Nothing cute in the tab bar, panes, menus, notifications, the answer card or the palette.
- While you type, ambient reactions wait and only state changes animate. With Reduce Motion, hops, walks
  and camera moves become short cross-fades.
- The camera never moves on its own. A drag turns the view, ⌘-drag slides it, and scroll or pinch zooms
  toward the pointer. In a narrow sidebar, scrolling scrolls the column of blankets.

## Look of the interface

- Neutral and solid: off-white surfaces, charcoal text, soft grey lines, soft shadows, smooth motion. No
  translucent panels, and no cream-and-brown palette.
- Mac conventions throughout: every command in the menus with its key, standard Settings (⌘,) with
  categories on the left and one setting per row on the right, and standard Save / Don't Save / Cancel.
- English and Japanese, following the system language, for everything a person reads: menus, settings,
  notifications, Help, and the words in the scene.

## The app icon

`docs/logo.svg` is the source of the app icon (`make icon` renders the asset catalogue from it): a black
cat peeking up from the bottom of a warm off-white tile, with ring eyes and small ears at its corners. No
neck, no tail, no mouth, no whiskers. It is the project's own cat. It is not a licence to use it as a mark;
see the README's licence section.
