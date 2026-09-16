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
| The two kinds of request, where they differ (Settings › Alerts, Help) | **Permission request**, **Question** | 許可のリクエスト, 質問 | prompt, elicitation |
| A turn that finished while you weren't looking | **Finished** | 完了 | done, idle, complete |

"Blanket", "cat", "lantern", "meadow" and "flag" are pictures, never labels. Only the Help page that
explains the pictures uses them, and the meadow's own editor (Edit Meadow, My Meadow, Revert to Default),
where the meadow is what is being worked on. "Picnic ground" is never a label: VoiceOver says where a thing
stands from it. "Session" is never shown, because people hear it as Claude Code's own
sessions.

## The window

- **One window, framed.** A **top bar** runs the window's full width (the traffic lights, the meadow
  button and Home; in the middle a search field, "Go to a workspace, tab or file ⌘P", which opens Go to;
  "+", the Files and Changes button and Settings at the end), and a **status bar** runs along its foot
  (branch, folder as `~/…/parent/folder`, how many Claudes and how many need you, the focused file's
  details, ⌘P and ⇧⌘P; short of room it lets go of the two keys, then the folder, rather than cutting
  every item short). Both are drawn by the app in the chrome colour, never as toolbar items. Between
  them the meadow is on the left and the work area on the right: a **tab row** led by the **workspace
  button** (its colour, its name, a chevron: a menu that opens as it is pressed, starting with New
  Workspace and Open Folder…, then Home and every workspace), then the panes. A terminal alone in its
  tab has no header; a file or a diff has a slim one with its path; in a tab of several panes every pane
  has one (see "Where the keys go"). Nothing in the bars repeats what is on screen elsewhere.
- **Sizes.** By default the meadow takes about 42 % of the window and the terminals keep at least 80
  columns. The divider drags from a 240 pt sidebar to the meadow alone. Below about 880 pt of window, the
  meadow steps aside; showing it then (⌃⌘S, the meadow button) gives it its narrowest sidebar beside the
  terminals, at any window size the app allows. View offers Meadow and Terminals, Terminals Only, Meadow
  Only, Hide Meadow, and Show Workspaces as List.
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
  `cd` until renamed. The meadow follows what you choose (see "The meadow follows what you choose").
- **Home** is a place, not a tab: no workspace selected. The meadow shows every blanket with none ringed,
  and the work area shows the Home page: the app's cat, Open Folder…
  (⌘O), New Terminal (↩), **Open** (the workspaces open now, in the meadow's order, each with its colour,
  name, branch, state and Claude count; Return takes you back in exactly where you left it) and
  **Recent** (folders not already open). The tab row shows "Home" and no tabs. It looks the same with no
  workspace or many. **Every launch lands on Home**; everything comes back running, one click away.
  Go › Home is ⇧⌘H; it is also the house in the top bar and the first place in the workspace button's
  menu (after New Workspace and Open Folder…). From a workspace, ⌘N (New Workspace) goes there, New
  Terminal ready for Return; on Home, it is New Terminal itself: a workspace with a terminal, at once.
  Home teaches nothing in sentences: its rows are the actions, and an empty meadow simply shows itself.
- **Nothing at launch asks.** Terminals still running in another version's session host, and the Claudes
  not resumed because of them, are a quiet bar on Home with Details and a close button, never a dialog.
- **Go to (⌘P)** reads its field as VS Code's Quick Open does: a name finds workspaces, tabs, Claudes and
  files; `>` turns it into the command list; `:42` goes to a line of the file shown; `name:42` opens a
  file at a line. Every space-separated word must match, and a quoted word matches as written. A match
  just after `/` beats one after `-` or `.`, and among names that start with what you typed, the shorter
  wins.
- **Closing** asks nothing (only about a file with unsaved changes, by its name). ⌘Z brings back what was
  closed, with its process, for ten seconds, and ⇧⌘T reopens it later; a pane comes back where it was,
  beside whatever its tab holds by then. Closing a workspace's last tab closes the workspace; closing the workspace on screen
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
| **Idle** (seen) | A loaf | None | None | Breathing; now and then a wander in the grass by its blanket (below) |
| **Napping** (idle a while) | Curled, where it is | A small "z" | Grey | As idle |

- **Finished until seen.** A finished turn keeps its "✓" until its pane has been on screen for a second.
- **The same marks everywhere.** Tabs, the workspace button, Go to and the Dock use the same marks.
  Request and error: a vermillion circle with a white glyph. Finished: a blue dot. A tab shows the most
  urgent mark of its panes, and helpers' requests roll up to their boss's tab.
- **A blanket of plain terminals has a camp kettle** where a cat would sit, beside the hamper: a small
  enamel kettle on a little brass stove, showing what the shells' command marks (OSC 133) say. Cold while
  the shell waits at its prompt. While a command runs it reads at a glance from the sidebar: the stove's warm
  light spills onto the blanket round it (stronger at night), flames lick out past its base, a plume of steam
  rises well above it and the lid tips as it rattles; after half a minute it calms to a steady simmer (a dev
  server), the glow kept, a lower flame and a calmer plume, and the meadow rests. A
  command that ends well: one whistle of steam, then the flame goes out (no sound; a command over in a
  moment, an `ls`, just goes out). One that fails: the flame is snuffed with a small dark puff and a little
  red flag stands by the kettle until its terminal has been seen. Running in one terminal and failed in
  another, both show. A shell that writes no marks keeps it cold rather than guessing. When a Claude starts
  there the kettle shrinks away as the cat arrives, and comes back, cold, once the cat has gone. With
  Reduce Motion or the animation off nothing drifts or rattles, but lit or out and the flag still read (a
  still wisp of steam over a lit kettle). VoiceOver reads the workspace with "Command running", "Command
  finished" or "Command failed".
- **Plain terminals** are lanterns, drawn only after dark: lit while a command runs, dark when idle, red
  when the last command failed and you have not seen it (seen: its pane on screen for a second in the
  window in use). The lanterns stand in one tidy row along the blanket's front edge, at
  most eight, failed first, then lit, then dark. More are counted on the flag as a small lantern and
  "+N", red when one counted has failed.
- **Faces stay toward the camera.** Every waking cat's face stays within 40° of the camera, whatever it
  is doing, so a working cat never reads as a dark lump.
- **Contrast.** Every bubble against the grass, and the black cat by day and by night, reaches 3:1 (WCAG
  1.4.11), in every sky and weather. At night each picnic's fireflies give the cats a warm rim of light.

## Attention

- **Nothing an agent does may take control.** No event may activate the app, raise or move the window,
  switch workspace, tab or pane, move keyboard focus, scroll the meadow, move the camera or open a
  popover. Only the user's own actions do those.
- **⌘J (Next Request)** goes to the oldest request, then the oldest finished turn, then back where you
  were.
- **Alerts** (Settings › Alerts): one row per event, each with its sound and a Notify box: Permission
  request (Claude Code's `PermissionRequest`, and `Notification` of a permission prompt), Question
  (`AskUserQuestion`, `ExitPlanMode`, elicitation), Finished (`Stop`), Error (`StopFailure`), Helper
  finished (`SubagentStop`), Bell (a plain terminal's bell). A sound is one of Whiskr's three (two rising
  notes for a request, two low notes for an error, one soft knock for a finish), the Mac's alert sound,
  one from `/System/Library/Sounds`, one you add (copied into the app's Sounds folder, at most 10 seconds,
  not silent), or None. By default requests, questions, errors and finished turns sound and notify,
  helpers are silent, and the bell rings the Mac's alert sound.
- **Sounds** play wherever you are, unless you are at that very terminal: on screen in the window you use
  and typed into in the last 8 seconds (you can see it). The bell rings even then, at most once a second.
  At most one alert sound every two seconds, the most important first, after a pause in typing. "Play
  sounds only when Whiskr is in the background" keeps them for when you are elsewhere.
- **Notifications** only while Whiskr is in the background: requests and errors (after a 2-second
  re-check), finished turns that took 30 seconds or more, and whatever else you tick. They are silent:
  the alert's own sound plays. Permission requests carry Allow and Deny. Settings › Alerts says whether
  macOS lets them through, with a way to turn them on; the question is asked when a Claude first works,
  if macOS has not asked yet.
- **Dock:** a badge counting requests, and a Dock menu listing who is waiting. **Pause Alerts** silences
  sounds and notifications for a while.
- **The bell.** A plain terminal that rings its bell out of sight puts a bell on its tab until you have
  seen the pane. It is heard as the Bell row says, at most once a second, unless alerts are paused, and
  notifies (once, out of sight) only if ticked. Claude's tabs keep their own marks.
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
- **The eyes are round whenever it is awake:** washing, stretching, nibbling, sipping tea, lying as a loaf,
  squinting into a gust, all with them wide open. Only a quick blink, sleep (they close in one unbroken
  movement as it dozes off) and being petted (squeezed shut) close them. A half-shut eye read as a squint.
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
  appear only at night. Garden lamps someone has placed light their own pools of warm white, and nothing more:
  away from them the night is as dark as ever.
- **The real sky.** Following the clock, dawn, day, dusk and night come with the real sun where you are:
  night once it is 12° below the horizon, twilight's blue at 5° below, dawn's pink or dusk's gold as it
  crosses the horizon, full day from 12° up. A polar winter's noon stays in twilight; a midsummer
  midnight sun stays gold. The moon is the real one: its phase, its lit edge toward the sun, up only
  between moonrise and moonset; a moonlit night is a little lighter than a moonless one (never darker than
  night always was). Worked out on the Mac; nothing asks where you are for it.
- **The sky is seen only with the view tilted low.** At the usual tilts the view looks down on the meadow
  and shows no sky. Tilted down as far as it goes (a drag), a band of sky shows over the far hills: the
  stars, thickest there, and the moon in the top left of the picture, wholly inside it, behind hills and
  trees when they stand in front of it. Both fade in through twilight and hide behind cloud.
- **Real weather** (off until you turn it on) shows only what reads in clay: cloud greying the sky and
  dimming the sun; fog, and haze when one cannot see far; the wind's strength, direction and gusts in
  the grass, flowers, seeds and rain (north is away from you along the meadow at its first angle);
  rain and snow from a light scatter to heavy; the grass pale in the cold and yellow in the heat; and in
  a thunderstorm, a soft sheet-lightning glow in the sky now and then. Lightning never flashes more than
  twice a second (two pulses at most, then ten seconds or more of none, WCAG 2.3.1), and never with
  Reduce Motion or the animation off. No sound. Each has its own switch in Settings › Meadow.
  Left out, having no picture: humidity, pressure, UV, apparent temperature; the service's day/night
  (the sun is worked out here); snow lying on the ground (bubbles must keep their contrast on the grass).
- **The land never ends in view.** At every tilt, zoom and size the ground and grass reach past the
  picture's edges: a far hill the view backs off over sinks away rather than fill the foreground, and
  the column's grass grows in front of a view looking along it from far down.
- **No streams or rivers.** That picture is kept for a second machine, which this app does not have.

### The meadow's scenery

The trees, plants, stones and things standing in the meadow are its **scenery**: a meadow document
(`.whiskrmeadow`), which people will be able to edit and share. The **Default** is the meadow as it has
always been, written out as such a document; it is never changed (editing it makes a copy). Every grown
tree dapples the ground beneath it (a young one is too small to). These rules govern everything a meadow
can hold (its catalog):

- **Made things are cat-sized; living things are their real size.** A bench is one a cat could sit on; an
  oak is an oak. Made things never scale; living things vary within a range.
- **Nothing in the scenery may look like a state or a workspace:** no extra blankets or rugs, flags,
  lanterns, bubbles, rings or cats, and no loose copy of a working cat's props (book, laptop, magnifier,
  lever machine, papers) lying in the grass. Books on a shelf and paper on a board are furniture.
- **Colours of made things come from each item's own small clay palette** (4–8 swatches), never a free
  picker; no palette holds the state colours (vermillion, finished blue) or the alert red.
- **The picnic ground is kept for the workspaces.** Big things cannot be put where blankets lie; small
  rooted things may, and make way when a blanket comes. Blankets are never placed by hand and never move
  for scenery.
- Everything above still holds: the same clay, plants modelled on real ones in clumps (no shrubs, no
  dandelion clocks), props that are real objects, nothing written in the scene, no streams.
- **Every new thing is looked up first:** how the real one is shaped, joined, coloured and weathered, and how
  it meets the grass, then simplified into the clay, rounded and a little chunky, with nothing thin enough to
  shimmer, readable on a 64 pt tile and from the editor's height. Plants keep their blooms about twice life
  size, as the meadow's always have (an apple too).
- **What the meadow holds today:** oak, birch, cherry, young tree, apple tree (hung with apples, windfalls
  beneath) and Scots pine (bare below, orange high on its trunk, a flat-topped crown of needle pads); daisy,
  buttercup, lupin, poppy, cornflower, foxglove, fern, clover and fly agaric; stone, mossy stone, boulder
  (a seat), stepping stone, fallen log, tree stump and log pile; a floor cushion (a zabuton); and Cat Things,
  sized for the meadow's cats: a cardboard box a cat fits in, its flaps fallen open; a sisal scratching post
  with a perch on top and a pompom; a ball of yarn; a round bed; a food bowl of kibble. Made things a cat uses
  stand on turf trodden short round them, as the grass flattens round a bed left out; found things (a stump,
  a boulder) stand in the long grass. Until the palettes come, each made thing wears its palette's first
  swatch (oat for the cushion, the yarn and the bed; cream for the bowl).
- **Garden lamps** (Workplace shelf): a lamp post as gardens and parks have them, cat-sized (a little over twice
  a cat's height): a flared cast base, a fluted post with a ladder bar, a four-paned lantern widening upward
  under an overhanging roof and a ball finial, in heritage green (never black: the cats are black). Like real
  ones on a light sensor they light by themselves once dusk has dimmed past sunset (the sun 2° down) and go out
  just after sunrise (1° up); at fixed hours, from a little after dusk's gold to a little before dawn's pink.
  They come on one by one over about half a minute, each catching with a stutter or two before burning
  steadily; with Reduce Motion or the animation off they are simply lit or out. Lit, the frosted glass glows
  with a soft halo (wider in mist, fog and rain), and a warm white pool (about 3,000 K, whiter than the
  picnics' candle amber) falls on the ground and grass round the post, brightest at its foot and fading over a
  few strides with no edge; it lights the near side of what stands in it, a tree's lower crown from below,
  and rain or snow falling through it. A lamp is kept off the picnic ground, so its light never competes
  with a blanket's lanterns and never reads as one; at most 32. Placing or moving one at night, its ghost
  already casts its pool, so a garden can be lit as it is laid out. By day it is an unlit lamp and changes
  nothing else in the picture. Settings › Meadow › Lamps light at night (on) leaves them unlit.
- **Cats will like them:** each thing that invites a cat says where (sit on a stump, a boulder, a log pile,
  the log, in a box or by a bowl; nap in a bed or on a cushion; scratch at a post). The meadow's cats do not
  go there yet.

### Editing the meadow

**Edit Meadow** (View › Edit Meadow, ⌃⌘E, checked while editing; also the grass's menu, Settings › Meadow's
Edit Meadow… and Go to's commands) makes the meadow theirs. No button in the top bar: it would sit unused
most of the time.

- **Going in.** The work area (tab row, panes, side panel) slides out as a region does and the meadow fills
  the window between the top bar and the status bar, whatever the layout was (the layout itself is not
  changed). The blankets keep the rows they had. The view glides up to look down on the meadow at about 55°,
  framing the blankets and the picnic ground with the scenery round them. The top bar's middle cross-fades
  from Go to's field to the meadow's name, "Editing “My Meadow”", a menu (Use Another Meadow, Revert to
  Default); its end shows Undo and Redo, each naming its step in its tooltip, and Done. The meadow's button
  rests while editing; Home leaves editing and goes Home. Nothing floats at the meadow's top: turning and
  framing the view live on the keys, in View › Editor View and in the grass's menu. With
  Reduce Motion everything cross-fades in place and the view cuts. The **tray** rises along the meadow's
  bottom edge and the view frames the blankets above it.
- **Coming out.** Done (⌘↩), Esc once nothing is under way or chosen, or View › Edit Meadow again. Esc
  steps back one thing at a time: the drag under way (it springs back), the marquee, the thing the keyboard
  went to, the choice, then editing itself. Any command that needs the terminals (⌘T, ⌘N, ⌘O, ⌘W, the
  layout's commands, the side panel) and any choice on the right (Go to, ⌘J, ⌃Tab, a notification) leaves
  editing first, then acts. Leaving brings back exactly the layout, the meadow's width, the view (then the
  meadow follows your choices as always) and the keyboard. Nothing is lost: every change is saved already.
- **Meanwhile** terminals keep running, cats keep acting and asking, alerts sound and notify, and the status
  bar keeps counting who needs you. Cats and blankets are not the editor's: a click on them does nothing.
  No agent event moves the view; only you do. No answer card and no edge capsules while editing.
- **The Select tool.** A click chooses a thing: a ring of the focus colour lies round its ground. ⇧-click
  adds or lets go; ⌘-click chooses everything of its kind within 30 units ("Select All Like This" in its
  menu); a drag on empty ground draws a dashed marquee and chooses what stands inside it; ⌘A chooses
  everything; a click on the grass lets go. Dragging what is chosen moves it, keeping the group's shape;
  ⌥-drag moves copies and leaves the originals. Where a thing may not stand its ring turns dashed (white
  within, the ink without, never colour alone) and the reason shows by the pointer: "Outside the meadow",
  "Kept clear for your workspaces", "Too close to the oak". Let go there and it springs back, the reason
  staying a moment. Only what an edit makes worse is refused: a thing already standing close to another (the
  Default's tight clumps) may still be nudged.
- **Keys** (while the meadow has the keyboard): arrows nudge a quarter unit along the view's right and
  forward (⇧: a whole one); R turns 15° clockwise, ⇧R back, ⌥ for 1°; `[` and `]` shrink and grow living
  things a step, within what their kind grows to (stones and made things keep their size); ⌘D duplicates
  beside (it is not Split Right while editing: no terminal is in view); ⌫ deletes; ⌘C, ⌘X, ⌘V copy, cut and
  paste at the pointer (between meadows too); `,` and `.` turn the view 45°, `0` frames the picnic ground
  again; Space held slides the view with a drag. With nothing chosen the arrows move a keyboard cursor (a
  ring of the focus colour), `[` and `]` go from thing to thing nearest it, and Return chooses. Tab goes on
  to the selection's bar.
- **Chosen trees** read at a glance from any height: besides the ring round the trunk, a lighter ring lies
  round the ground the crown shades, and the tree's own colours are lit a little brighter (never tinted: an
  oak stays an oak's green, a cherry pink). Plants and stones keep their ring on the ground.
- **The selection's bar** hangs 12 pt under the rings round what is chosen (over it when there is no room
  below, never over the tray), so it stays beside the choice however tall a tree is, and follows it as the
  view moves: Turn Left, Turn Right; Smaller, Larger and Shuffle for living things (Shuffle draws a
  new size, lean and turn, and a tree a new seed); Duplicate, Delete; More (Select All Like This, Copy,
  Paste). A floating piece: the chrome's colour, a line, radius 10, the one soft shadow.
- **The tools** are in the tray and in View › Editor Tools (Select, Brush, Erase, Ground), checked as chosen.
- **The tray** floats along the meadow's bottom edge (the chrome's colour, a line, radius 10, the one soft
  shadow; as wide as the meadow allows, at most 1,040 pt). Its top row: the tools, **Select (V)**, **Brush
  (B)**, **Erase (E)** and **Ground (G)**; the Brush's, the Eraser's and the Ground tool's size (`[` `]`, a
  unit at a time, or the slider) and the Brush's density (Sparse, Natural, Dense);
  "4,212 of 5,000 things" or "40 of 48 trees" only past 80 % of a cap; the filter field (⌘F, which the editor
  takes from Find while editing: it finds across categories by a thing's name, its shelf's and the other words
  it goes by, "firewood" for the log pile, "zabuton" for the cushion, "cat" for every cat thing, and in
  Japanese hiragana or katakana alike; Return arms what it found); and the fold (View ›
  Hide Editor Tray, ⌥⌘T, remembered) that leaves only that row. Below: the categories that hold something
  (Trees, Flowers, Stones & Wood, Ground, whose tab is the Ground tool's, Workplace and Cat Things; keys 1–7), a line saying what to do now, and the shelf: each thing pictured
  by the scene in its own clay on a round of grass, by day, on a tile of the content colour (64 pt, its name
  under it, a long name a little smaller rather than cut). Under 760 pt the tools and categories show as symbols with their names in the tooltips. The shelf
  offers exactly what the meadow can draw. A shelf longer than the tray scrolls along with a trackpad's swipe
  or a mouse's wheel (up and down both go along it); the wheel over the tray never zooms the meadow behind it.
  Tab (⇧Tab) gives the shelf the keyboard (← → along it, each tile brought into view, Return
  chooses, Tab or Esc back to the meadow); with Full Keyboard Access every control is reachable as usual, and
  VoiceOver reads the tools, the tabs and each thing by name, the chosen one as selected.
- **Placing.** A click on a tile arms the thing: its ghost (see-through, as it will stand, with its own size,
  lean, shape and, for a tree, seed: no two oaks alike) follows the pointer over the ground with its ring and
  a tick for which way it faces; R and ⇧R turn it (⌥: 1°; ⌥-scroll too). Where it may not stand the ghost
  greys, the ring is dashed and the reason shows by the pointer. A click places it (one step, "Place Oak"),
  chooses it and puts the tool back to choosing; ⇧-click places it and keeps a fresh one armed; a click where
  it may not stand places nothing and keeps it armed; Esc puts it back. A tile can be dragged straight out
  onto the meadow (let go over the tray, nothing is placed), and double-clicked to place it at once near the
  middle of the view. From the keys: Tab to the shelf, ← →, Return; the ghost waits at the keyboard's cursor,
  the arrows move it, Return places it there or at the nearest spot round it where it may stand. A placed
  thing settles into the meadow (92 % to its own size in 160 ms; with Reduce Motion it is simply there).
- **Stepping stones** (Stones & Wood) are placed with a click like any thing, or laid in a row: a drag lays
  one where it was pressed and one each stride (1.1 units) along the drag, each set across the way as a
  person lays them (its long side square to the path, give or take a little, a hair off the line, a little
  wider than deep, its own size and turn), with a strip of grass between each two and the turf trodden short
  round them; one that would stand too close to something is left out and the row goes on. The row is one
  step ("Lay 9 Stepping Stones") and is chosen once laid (⇧ keeps stones armed for another). They are the
  worktrees' own stepping stone, its top levelled as a laid stone's is.
- **The Brush** paints the plants of the Flowers shelf, or the **Wildflowers** mix (the meadow's own:
  daisies, buttercups, lupins and poppies in the shares it grows them). Its circle lies on the ground under the
  pointer. A stroke drops a clump every half radius: a loose clump of one kind, thicker toward its middle,
  each plant turned, sized and leant its own way, none overlapping anything, so the meadow never gets an
  even sprinkle; the whole stroke is one step ("Brush Daisies"). ⌥-drag clears what the Brush paints. Return
  plants one clump at the keyboard's cursor. Stones, wood and trees are placed one by one, never brushed.
- **The Ground tool** paints the ground under its circle (1–10 units, 2 to start): **Path** (dry, trodden
  earth, a pale sandy tan worn smoothest along its middle, a few pebbles pressed in, short tufts holding on
  along its sides and the grass closing in over its edges, so it looks walked, not drawn), **Lawn** (grass mown
  short, with the mower's gentle stripes), **Soil** (dark, crumbly tilled earth in low ridges, drier crumbs on
  their crests, darkest where the bed is cut from the turf), and **Wild Grass**,
  which brings the meadow's own long grass back (⌥-drag does the same with any paint chosen; the circle is
  then drawn dashed, as the Eraser's). Grass is hidden on path and soil and cut short on lawn; plants are
  not touched (paint soil, then brush flowers into it). Path and soil are told apart at a glance from any
  height, by day, at dusk and by night. Edges are soft and uneven, as grass grows back. Paint
  may cross the picnic ground; a blanket always lies on its own ground, the paint fading out round it. Each
  stroke is one step ("Paint Path"); Return paints at the keyboard's cursor. The shelf's tiles are pictures of
  the meadow's own turf, painted. A meadow file can hold only so much detail: a stroke that would pass it
  stops and says so ("The ground holds as much painting as a meadow can keep"), so a meadow is never painted
  into one that cannot be saved.
- **The Eraser** (a dashed circle in the ink): a click takes away the thing under it, a tree too; a drag
  sweeps away the plants, mushrooms and stones it passes, never a tree, a young tree, wood, a boulder or a made
  thing (nothing big or placed with care is lost to a stroke passing it), and never a blanket or anything from
  a newer Whiskr. Choosing a kind on
- **The Eraser** (a dashed circle in the ink): a click takes away the thing under it, a tree or a parcel too; a drag
  sweeps away the plants, mushrooms and stones it passes, never a tree, a young tree or the log (nothing big
  is lost to a stroke passing it), and never a blanket or anything from a newer Whiskr. Choosing a kind on
  its shelf sweeps only that kind ("The Eraser clears only daisies now" where a click falls on another).
  Each click or sweep is one step.
- **Caps.** A meadow holds at most 5,000 things, 48 trees, 120 tall things and 32 garden lamps. The
  tray says how full the meadow is past 80 % of a cap; at one, the tiles of what cannot be added say why
  ("The meadow has as many trees as it can hold (48)"), the ghost and the Brush say it by the pointer, and
  nothing is ever cut short silently.
- **Esc** steps back: the gesture under way (a stroke is not kept), the thing armed, the Brush, the Eraser or
  the Ground tool (back to Select), the choice, then editing itself.
- **The view while editing:** a plain drag is the tool's; ⌘-drag, right-drag or Space-drag slides; two
  fingers turn; scrolling and pinching zoom toward the pointer, nearer than usual (5 units); the view roams
  the whole meadow. `,` and `.` turn it 45°, `0` frames the picnic ground again; with a pointer alone, View ›
  Editor View and the grass's menu (right-click) hold Turn View Left, Turn View Right, Face North and Frame
  the Picnic Ground.
- **The picnic ground** is drawn while editing as a soft dashed outline (x within 20 of the column's lane,
  z from −3 to 120), with no words. The column's lane is always x = 0. Trees, young trees and the log cannot
  stand there; flowers, stones, stepping stones, mushrooms and paint may, and like trees and the log anywhere
  make way when a blanket comes.
- **Undo.** ⌘Z and ⇧⌘Z (Edit › Undo names the step, "Undo Move Oak") take back each gesture: a drag, a
  nudge, a turn, a size step, a duplicate, a deletion, a paste, a shuffle, a placing, a row of stepping
  stones, a Brush stroke, an Eraser's click or sweep, a Ground stroke, choosing another meadow. Undoing
  chooses what the step changed. The history lasts for the app's session, across leaving and coming back to
  editing and across meadows; outside editing ⌘Z keeps bringing back what was closed.
- **Saving.** Every change is saved a second after the last, and at once on leaving and at quit. The Default
  is built in and never changes: the first change makes "My Meadow", a copy, and shows it, in the same step
  (undone, the Default is shown again and the copy goes). Revert to Default shows the Default; your meadow
  stays. Settings › Meadow's Your Meadow chooses which is shown.
- **VoiceOver** reads the edited meadow as its trees, wood, boulders and made things one by one and its plants and stones as clumps
  ("Daisies, 9"); each element chooses what it stands for. Choosing, moving, the tool, what is armed, placing,
  strokes, refusals with their reason, undo and redo are announced. With Increase Contrast the rings, the
  circles, the picnic ground's outline and the tray's line are drawn stronger.
- **Things from a newer Whiskr** (and things of the catalog this Whiskr has no model for yet) are kept whole and
  never drawn outside editing; while editing each shows where it stands as a **parcel** (a kraft-paper box tied
  with string, neutral on purpose), which can be chosen, moved and taken away and nothing more (its bar holds
  Delete and More only; R, `[` `]`, ⌘D and Copy say "Things from a newer Whiskr can only be moved or taken
  away"). Pointed at, it says what it is ("Thing from a newer Whiskr · Kept whole: move it, or take it away"),
  and VoiceOver reads the same. A quiet note along the top of the meadow says how many there are ("Made with a
  newer Whiskr: 6 things can't be shown here. They're kept, and come back when you update."); its × puts it
  away for that meadow.

### My Meadows and meadow files

Meadows are files people keep, share and receive: `.whiskrmeadow`, plain JSON, data only (the format:
docs/ARCHITECTURE.md, "The meadow file").

- **My Meadows** is a card for each meadow: the read-only **Default** first ("Built in · never changes"), then
  yours in name order ("Orchard", "Orchard 2", "Orchard 10"). Each card is the meadow's picture, drawn by the
  meadow itself from the meadow's data (by day, still air, low over the picnic ground toward the hills; no
  blankets, cats or flags, which are yours and not the file's), its name, and what it holds ("214 things ·
  paths and lawn", "Nothing placed yet"). The meadow shown is ringed and checked. A click on a picture shows that
  meadow (the Default's is Revert to Default), a step ⌘Z takes back while editing. Its ⋯ (or a right-click):
  Use, Edit, Rename, Duplicate, Export…, Share…, Export Picture…, Show in Finder, Move to Trash…. Under the
  cards: New Meadow (From the Default, or Empty: shown and edited at once), Import… and Edit Meadow…. It is
  Settings › Meadow's first section, and a sheet from the editor's name menu (My Meadows…).
- **Pictures** follow the meadow: drawn again when its file changes (by you, a sync tool or the Finder), kept
  in memory otherwise. They hold no colour of the theme, so one picture is right in every theme; the cards
  round them are the theme's.
- **Rename** happens in the card: the name becomes a field, Return keeps it, Esc leaves it. It is trimmed and
  made plain text; an empty name or one over 60 characters says why under the field; a name another meadow
  has takes the next free one, said before Return ("Another meadow has this name; this one becomes “Orchard
  2”"). The file and the name inside it change together; the meadow shown stays shown, and steps made before
  still find it. The editor's name menu has Rename “…”…, which opens My Meadows with the name ready.
- **Duplicate** makes the same meadow under the next free name of its family (a copy of "Orchard 2" is
  "Orchard 3", never "Orchard 2 2"); the Default's copy is "My Meadow". **Move to Trash…** always asks,
  naming the meadow ("Move “Orchard” to the Trash?"; for the meadow shown, that the Default is shown
  instead); the Finder's Put Back brings it back. The history ends there (its steps no longer fit).
- **Export…** (the card, File › Export Meadow…, the editor's name menu) is the save panel with two optional
  fields: "Made by:" (your name, shown with this meadow; offered again next time, never added unasked) and
  "About it:". **Share…** hands the file to the system's share picker; a card **dragged out** to the Finder
  becomes the file where it lands. Each is the newest format, sorted keys, the name it has here: nothing of
  your Mac, folders, workspaces, the date or you. **Export Picture…** saves the card's picture large
  (2400 × 1500) for a post or a gallery.
- **Import** (File › Import Meadow…, My Meadows' Import…, a double-click or Open With in the Finder, a file
  dropped on the meadow, on My Meadows or on the Dock icon) always goes through the **import sheet**, one file
  after another: the meadow drawn from its data, its name, "by Hana · Made with Whiskr 1.8.2", its line in
  quotes, what it holds, and what to know (things this Whiskr cannot draw, kept and back once updated; a newer
  way of writing meadows, read in part and saved back untouched; things outside the meadow left out; a name
  you already have, added as "… 2"). Cancel (Esc), Add to My Meadows, Add and Use (Return). Adding never
  replaces a meadow; the file is added as it came. A file that cannot be opened says why and what to do, in
  the same sheet: "“Orchard Study” needs a newer Whiskr · It was made with Whiskr 3.2.0, which saves meadows in a
  way this version can't read. Update Whiskr to open it.", damaged ("it ends part way through, as a download
  that stopped early does"), too large, too many things ("5,001 of 5,000"). Every text from a file is shown as
  plain text only.
- **Changed on disk.** The Meadows folder is watched: a meadow added, renamed or removed in the Finder or by a
  sync tool shows as it is. The meadow shown, changed by something else, is read again (nothing of yours is
  unsaved: changes are written within a second); while it is being edited, a quiet note asks ("“Orchard”
  changed on disk. Keep yours, or reload it? The other is kept in My Meadows."): **Keep Mine** writes yours
  and keeps the disk's as a meadow of its own, **Reload** shows the disk's and keeps yours as one. Removed
  while edited: **Save Again** or **Close It**; removed otherwise, the Default is shown and Settings › Meadow
  says why. Nothing is written over the file while the note asks; leaving editing unanswered reloads, keeping
  yours.
- **In the Finder** a meadow file is "Whiskr Meadow" with its own icon (a round of meadow, a tree, our cat
  peeking up), and opens in Whiskr.

### Idle cats wander

A cat whose Claude has nothing for it (idle or awake at its prompt, no request, no finished turn unseen, no
error) gets up after a while and wanders near its blanket, as real cats do, in this cat's own way: its paws are
short fixed nubs, so a walk is a waddle that lifts it a little with each step, a bound through the long grass
is a few hops with a look round between, and it moves on only while it is up off its paws, so it never slides.
It turns before it sets off. At each stop it sits up to watch whatever flies past, sniffs a flower, or lies as
a loaf, then goes on or wanders home. Out in short bursts, with long still stops between, so the meadow rests
between them as it always did; in a meadow of many idle cats, two at most are out and about at once.

- **Its afternoon.** Its Claude may let it nap soon after its turn; it stays up and about on and off for four
  to six minutes first (each cat its own), then naps, and after a long nap (twenty minutes to three quarters of
  an hour) now and then wakes, stretches, takes one short outing and naps again. A meadow of idle cats is
  gently alive over an afternoon and still rests between their bursts.
- **The meadow's things.** What invites a cat is used, one cat at a time and preferred to bare grass when it
  is in reach: it hops up to sit on a stump, a boulder, a log pile or the fallen log, sits in a box (and naps in
  it), naps in a bed or on a cushion, stands up at a scratching post for a scratch (its paws stroking down in
  turn, never lengthening), and looks in the bowl. Things that make way for a blanket (shrunk near one) are
  not used. The ball of yarn is left as it is: a cat batting it would need the ball to answer, and a ball that
  only rocks in place reads as a mistake, so it stays a picture.
- **Paths.** Routes and stops take the ground cats like (`MeadowView.walkingEase`): a painted path or stepping
  stones when one is near, lawn before long grass; stepping stones are walked on, not gone round.

- **Its own patch.** Within a few cat-lengths of its blanket's edge, nearer its blanket than any other, clear
  of other blankets and every flag, and in view: whose cat it is always reads, and its blanket's flag stays on
  its blanket. It goes round trees, stones, logs, flowers, whatever the meadow holds, the picnic things and
  other cats, never through them. Helpers do the same round their boss's blanket. For one of the meadow's
  things it goes a little further, to where things stand whole.
- **Work calls it home.** The moment its Claude works, asks, finishes or fails, it turns and runs home, ears
  flat, low fast bounds, and skids to a stop on its blanket, then takes up its pose. Nothing waits for the
  run: its bubble is up as it runs, and the tab, the status bar and the blanket's ring say so at once.
- **Napping anywhere.** It naps where it is, or first goes to a free bed, box or cushion, a tree's shade or
  back to its blanket, circling once before it curls up. Woken by work, it runs home the same way (down off a
  stump, out of a box, with a hop first).
- **Off** with Settings › Meadow › "Cats wander when idle", Reduce Motion, or the animation off: cats then stay
  on their blankets, and one out comes home at once.
- A cat out in the grass is pointed at, clicked (choosing its terminal) and read by VoiceOver as on its
  blanket.

### Motion

- Every cute reaction (a cat arriving or trotting off, a butterfly landing on a napper, a glance at the
  pointer) is anchored to its spot, lasts 2 seconds or less, and never plays on a cat with a request. An idle
  cat's wander (above) is the one outing, and it ends the moment anything is asked of it.
- Nothing cute in the top bar, tab row, status bar, panes, menus, notifications, the answer card or the
  palette.
- While you type, ambient reactions wait and only state changes animate. With Reduce Motion, hops, walks
  and camera moves become short cross-fades.
- **Animate Meadow** (View, and Settings › Meadow › "Animate the meadow"; WCAG 2.2.2). Off, the grass,
  butterflies, fireflies and the cats' fidgets hold still, and there is no lightning; state changes still show, as cross-fades, and
  a still meadow draws nothing between changes. Until you choose, it follows Reduce Motion.
- The camera moves only for you: a drag turns the view, ⌘-drag slides it, and scroll or pinch zooms
  toward the pointer (in a narrow sidebar, scrolling scrolls the column of blankets); and it follows your
  choices on the right (below). Once you have moved it yourself, it stays until you choose something
  else, and it never moves while you hold it. No agent event moves it.

### The meadow follows what you choose

Choosing a workspace, tab or pane yourself (a click, a key, a menu, Go to, ⌃Tab) brings its blanket, and
the cat of its Claude, comfortably into view: wholly inside the meadow with 12 pt to spare (in the
sidebar's column, above and below). It glides there in under a second, moving no further than it must and
keeping your angle and zoom; it backs off only when the blanket cannot fit. Already in view, nothing moves.
A quick run of choices moves it once, to the last. The cat you are in is marked by a soft pool of light on
the cloth and a pale ring; a plain terminal's blanket is ringed. Home frames the blankets again. Hidden,
the meadow does nothing and is there at once when shown. With Reduce Motion or the animation off it cuts.

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
| **Line** | Between any two regions: under the top bar, along the tab row's foot, after each tab, above the status bar, at the meadow's edge, before the side panel | `line`: at least 1.3:1 on both layers; 3:1 with Increase Contrast |
| **Line between panes** | Between two panes of a tab, which share the content's colour on both sides | `lineStrong`, at least 1.5:1 on the content (an imported theme's moved toward its text if it falls short); `textTertiary` with Increase Contrast |

The meadow is its own region, full height between the bars, edged by a line; nothing of the chrome is
tinted toward its green. Colour in the chrome means state, never decoration.

**Dividers** show they can be dragged as VS Code's do: once the pointer has rested on one for 300 ms
(passing over shows nothing), it turns the accent colour, 3 pt wide, and stays so while dragged, moving
with it; it goes as soon as the pointer leaves, and nothing of it stays behind. The resize cursor comes
at once. This holds for every divider: the meadow's edge, between panes, the side
panel's edge.

**Increase Contrast:** lines go to 3:1, secondary and tertiary text step up one level, and the selected
tab's line and the focused pane's header's are 3 pt. A theme that forces light or dark keeps it.

### Where the keys go

- **The selected tab** is the content's colour and opens into its panes (no line under it), with a 2 pt
  accent line along its top: two signs, as VS Code's. Unselected tabs are the chrome's colour with
  secondary text.
- **The panes of a split tab** each have a header: what the pane is (a Claude's state mark, a terminal, a
  file with its place, changes), its title (a terminal's folder after it), and at its end Zoom Pane and
  Close Pane. The pane you type in has its header tinted with the accent (9 %) and a 2 pt accent line
  along its foot; the others fade 10 % toward the background. Not a line along the header's top (a pane at
  the top of the tab would draw it under the tab row, shutting the selected tab off from its panes) and
  not a border round the pane (it read as a stray box). A pane alone, or one zoomed, has no terminal
  header and shows neither.
- **When the window is not the one in use** (neither main nor key: the palette, a panel of its own, does
  not count), the accent turns grey (`lineStrong`) and the bars' content goes quieter, as every Mac title
  bar does. Hover and pressed fills are the primary colour at fixed strengths, not theme colours.
- **Keys from VS Code where they are free.** ⌘B hides the meadow (the side bar's key), ⌘\ splits,
  ⇧⌘V previews Markdown, ⌥⌘S saves all, ⌃G goes to a line, and the line keys above, each a
  second key beside the Mac one where both exist. A key without ⌘ belongs to the editor only while it has
  the keyboard; in a terminal it goes to the program, so ⌥ stays Meta and ⌃ keys reach the shell. VS
  Code's meanings that would take a terminal's key or fight a Mac convention are not taken: ⌃\` (its
  terminal) stays the shell's, and ⌘1–3 (its editor groups), ⌥⌘ arrows (its editor tabs) and ⌘J (its
  panel) keep Whiskr's meanings: tabs, panes and Next Request. No menu key is ⌥ (or ⇧⌥) with a letter or
  digit: that types a character on many keyboards, which the menu would take from the editor (VS Code's
  ⌥Z for Wrap Lines is "ż" on a Polish one, "Ω" on a US one), so Editor › Wrap Lines has no key.
  `KeyTable` in the Kit lists every key, and a test checks that no two collide and that none takes a
  typed character.
- **The keyboard is always visible.** The rename field in Files shows the system focus ring. With Full
  Keyboard Access, Tab goes top bar → tab row → content → side panel → status bar.

Panes meet flush with a line between them (as Xcode and VS Code), not as cards with gaps: the selected
tab must join its panes, and the meadow beside them is already the window's one picture.

### Measures

- **Spacing:** 4, 8, 12, 16, 24, 32 (2 and 6 inside a control).
- **Radii:** 4 for small things (key caps, badges), 6 for controls (buttons, fields, rows), 10 for what
  floats (palette, cards, popovers). Bars, tabs and panes are square: they meet edge to edge.
- **Heights:** top bar 40 (the compact title bar's band: the traffic lights sit centred in it), tab row
  34, file header 30, status bar 24; controls in the bars 26 tall, icon buttons 28 wide. The status bar's
  items keep 16 pt from the window's sides, clear of its rounded corners.
- **Type:** tab titles 13 (medium when selected), the top bar's field 12, status bar, panel headers and
  breadcrumbs 11, Home's title 22. Nothing under 10.
- **Icons:** SF Symbols, 13 pt regular in the bars, 11 pt in tabs, headers and the status bar. Files
  (in Files, tabs, Go to, Changes and the file's header) show Seti's glyphs, the file icons VS Code shows by
  default, at the same sizes and in one colour, the text's: colour in the chrome means state, and git
  letters already carry it. Folders keep SF Symbols (Seti has none).

### States

Every control in the bars has the same hover (the primary colour at 6 %), pressed (11 %) and selected
(9 %) fills, and a tooltip naming it with its key. Disabled controls are at 40 %. A control acts as its
Mac counterpart does: a menu opens as the button goes down, under it and aligned to it, the button shown
pressed while it is open; a button acts when released over it. Pressing a control never moves the window;
only the bars' empty stretches do. The search field is the
content's colour inset in the chrome, its line darker under the pointer.

### Motion of the interface

One small set of durations and one curve (`Look.Motion`), so every change in the window feels like the
same app: **quick** 120 ms for a control's own feedback (hover and pressed fills, the selected tab's mark
moving over), **standard** 160 ms for something appearing or going in place (a tab, Go to and its list, a
bar, a card, the ⌃Tab list, Home and back), **region** 200 ms for a region sliding in or out (the side
panel, the status bar; the meadow at its split view's own pace); all on one ease-out. No springs.

- **The action never waits.** A tab is chosen, opened or closed at once, the keyboard goes where it should
  in the same moment, and a click lands on what is there now; only the picture eases. Nothing that is going
  takes a click or a key: a closing tab has already left the row's reach, a fading overlay takes neither.
- **Floating pieces** (Go to, the command palette, the worktree panel, the ⌃Tab list, the find bar) fade in
  while growing from 98 % of their size, from where they are anchored, and go the same way reversed. Go to
  opens out of the top bar's search field.
- **Lists change at once; their edge moves.** When Go to's list grows or shrinks, the rows are there
  immediately and the card's foot eases to its new place.
- **Regions** slide by Core Animation and are laid out once, not on every frame.
- **Reduce Motion:** nothing moves or scales; floating pieces only fade, Home and a workspace cross-fade,
  tabs, edges and regions are where they end at once.

### Tabs

- Tabs share the row equally up to 220 pt. When even 128 pt each will not fit them all, split tabs keep
  only their focused pane's title (their other panes become 36 pt icons); when that will not fit either,
  the row shows as many as fit, a run of neighbours that always holds the selected tab whole (it moves
  only when the selected tab would leave it), and a chevron with how many are out of sight, whose menu
  lists every tab. The row never scrolls: every tab in sight is whole, its close buttons in reach. "+"
  follows the last tab, as in Chrome (after the chevron when the row overflows), and moves with the tabs.
  New tabs come only from "+", ⌘T and the menus: the row's empty stretch after "+" belongs to the window,
  as the top bar's does. Tabs slide into place as others open, close or move. The top bar's "+" is a menu
  of every way to start something (New Tab, New Workspace, Open Folder…, New Worktree…); the row's is New
  Tab.
- **A split tab is one tab of segments, one per pane** in the panes' order, as Chrome draws a split view:
  each segment as a tab of one pane is (what it is, its title, its marks, its close button), a short line
  between segments and the full line only after the tab, the selected tab's fill under all of it and its
  focus line over the pane with the keyboard. A click on a segment shows that pane with the keyboard (the
  meadow follows). A segment's ×, a middle click on it and Close Pane in its menu close that pane alone,
  as ⌘W does; Close Tab (⌥⌘W, its menu's "Close Tab (2 Panes)") closes them all. There is no single
  close button for the whole: on a split tab one read as closing the pane it named. A segment shown as
  an icon has no close button (its tooltip names it; its menu and its pane's header close it). A name
  given to a split tab leads its segments as a small label; a tab of one pane shows the name as its
  title. Wherever a tab is named in a line (Go to, ⌃Tab, the list of every tab, VoiceOver) a split tab
  is its panes' titles in order: "Claude Code, notes.md".
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
- **Drag a tab, and see what a drop will do before letting go.** Picked up, the tab (a split tab whole)
  hangs from the pointer where it was grabbed, 3 % larger with a soft shadow, trailing on a critically
  damped spring and swinging up to 4° with its speed across, level at rest. Over the tab row the other
  tabs part where it would land (the gap is the preview; "+" moves with them). Over a pane's outer tenth
  (right, left, top or bottom) a tinted, rounded area is exactly the half of the pane it would take,
  labelled "Split Right" and so on; over the middle it is the whole pane, "Move Here" (the tab takes
  that pane's tab's place in the row and shows), and the row shows that place too. The area glides from
  zone to zone and holds a little past each boundary, so it never flickers. Over another workspace's
  blanket in the meadow, "Move to “name”". Anywhere else, or over its own panes, it fades: let go there,
  or press Esc, and it springs back to its place. Dropped, it springs into the place it went to (a pane
  it became: it shrinks into it). With Reduce Motion it follows the pointer exactly and fades where it
  lands. Terminals, files and diffs alike. When the row overflows, a drop in the row lands among the tabs
  in sight.

### Elsewhere

Mac conventions throughout: every command in the menus with its key, standard Settings (⌘,) with
categories on the left and one setting per row on the right, and standard Save / Don't Save / Cancel.
Each theme's card in Settings shows it as it will look once chosen: on a light Mac, a theme with both
versions shows its light one even while a dark-only theme holds the app dark; a card shows the chrome, a
terminal sample with its selection and cursor, and the sixteen colours. Two built-in themes are
Whiskr's own: Whiskr (the default, light and dark) and Graphite (dark only: neutral near-black greys with
no colour cast, the bars a step darker as the guarantees ask, soft white text, a restrained blue).
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
