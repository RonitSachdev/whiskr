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
- Idle cats wander: a cat whose Claude has nothing for it now and then gets up and wanders the grass near its
  blanket, a waddle or a few hops at a time, stopping to watch a butterfly, sniff a flower or lie as a loaf,
  going round trees, stones, flowers, picnic things and other cats and keeping to its own patch, in view.
  The moment Claude has work it runs home, ears back, and skids onto its blanket; its bubble and the tab say
  so from the start. Long idle, it naps out there, in a tree's shade or back on its blanket. Settings › Meadow
  › Cats wander when idle (on by default); never with Reduce Motion or the meadow's animation off. The meadow
  still rests between outings. An idle cat is up and about on and off for some minutes before it naps, and
  wakes now and then from a long nap for a stretch and a short outing. Cats use what the meadow offers them:
  they sit on stumps and boulders, benches, writing desks and planters' edges, on a shed's doorstep and under a
  nest box, sit and nap in boxes, nap in beds, on cushions, on bookcases and on a tent's threshold, scratch
  posts and look in bowls, one at a time, and take painted paths and stepping stones when one is near. They
  go round lamp posts and fences, and into a fenced garden with a bound over its gate.
- A workspace of plain terminals has a camp kettle on its blanket instead of an empty cloth: cold at the
  prompt, lit, glowing and steaming while a command runs (it reads at a glance from the sidebar) (calming to a simmer for a dev server), a whistle of steam
  when it ends well, and a little red flag when it fails until you look at that terminal, all from the shell's
  command marks. It makes way for the cat when Claude starts there. VoiceOver reads "Command running",
  "Command finished" or "Command failed".
- Every one of the meadow's twelve landmark trees dapples the ground beneath it with moving shade; the
  four farthest, out in the haze, used to stand in unbroken sun.
- Every tree reads as its kind from the editor's height and the sidebar as well as from the side: crowns of
  overlapping masses of leaves, each one soft canopy in lobes and bays with gaps where the limbs show, in the
  meadow's own bright colours, instead of a few big smooth lumps; each kind as tall and wide as before. An oak spreads in a broad dome; a birch is narrow and airy over a white trunk
  marked with black; a cherry's blossom gathers in clouds along its branches; an apple tree is low and open
  with small apples among its leaves; a Scots pine carries flat dark plates high on its bare trunk. They cost
  less to draw than before (the apple tree and the pine about half), and the Default meadow keeps every
  flower, stone and cat where it was.
- Edit Meadow (View › Edit Meadow, ⌃⌘E; also the grass's menu, Settings › Meadow and Go to): the
  terminals slide away and the meadow fills the window, seen from above. Choose its trees, flowers, stones
  and the log with a click, ⇧-click, ⌘-click (all of a kind nearby) or a marquee; drag to move them (⌥-drag
  copies), with a ring under each and, where one cannot stand, a dashed ring and the reason by the pointer;
  arrows nudge, R turns, [ and ] size living things, ⌘D duplicates, ⌫ deletes, and ⌘C, ⌘X and ⌘V copy and
  paste. A bar floats over what is chosen; `,` `.` and `0` (or View › Editor View, or the grass's menu) turn
  the view, face it north and frame the workspaces again. Every gesture is one
  step of ⌘Z and ⇧⌘Z. Everything is saved as you go: the first change makes "My Meadow", a copy of the
  Default, which never changes, and Revert to Default (the meadow's name in the top bar, or Settings ›
  Meadow) shows it again. Done (⌘↩) or Esc brings the window back exactly as it was; terminals, Claudes and
  alerts carry on throughout, and ⌘J, ⌘T and choosing anything on the right leave editing first.
- The meadow's editor has a tray along its bottom edge: Select (V), Brush (B), Erase (E) and Ground (G), the
  shelf of everything the meadow can hold, each pictured by the meadow itself in its clay, by category (1–4) or by
  filter (⌘F), folded to one row with ⌥⌘T. Click a thing and its ghost follows the pointer, greyed with the
  reason where it cannot stand; a click places it (⇧-click places more), or drag it straight out of the tray;
  each one grows its own size, lean and shape (no two oaks alike) and settles into the meadow. The Brush
  plants loose clumps of flowers (or the meadow's own wildflower mix) along a stroke, never an even sprinkle,
  with a size and a density; ⌥-drag clears. The Eraser takes away what you click, or sweeps plants and stones
  (one kind, if you like) and never a tree. Every placing, stroke and sweep is one step of ⌘Z. The tray says
  how full the meadow is before a cap is reached (5,000 things, 48 trees, 120 tall things) and why at one.
  All of it works from the keyboard alone (Tab to the shelf, Return to arm, arrows to move, Return to place)
  and with VoiceOver.
- A chosen tree in the editor is ringed round its crown's shade as well as its trunk and lit a little
  brighter in its own colours (no longer tinted blue), and the bar for what is chosen hangs just under its
  rings instead of high above the crown.
- The editor's Ground tool (G): paint paths of worn earth (the grass closing in over their edges, so they
  look walked rather than drawn), lawn mown short with the mower's stripes, and soil for flower beds, and
  bring the wild grass back with Wild Grass or ⌥-drag. The brush follows the ground, `[` and `]` or the
  slider size it, each stroke is one step of ⌘Z, and the meadow keeps its frame rate while you paint. Plants
  are left as they are; blankets always lie on their own ground. The painting is saved in the meadow's file.
- Stepping stones: on the Stones & Wood shelf; a click places one, a drag lays a row a stride apart, each
  set its own way across the path with the turf trodden short round it, as one step.
- More to make the meadow theirs, each modelled on the real thing in the meadow's clay: an apple tree with
  apples among its leaves (a few windfalls in the grass) and a tall Scots pine, orange high on its trunk; cornflowers,
  foxgloves, ferns and clover for the Brush; a boulder to sit on, a tree stump with its rings and a log
  pile; a floor cushion; and Cat Things: a cardboard box with its flaps open, a scratching post, a ball of
  yarn, a cat bed and a food bowl, the grass trodden short round them. The shelf scrolls with a mouse's
  wheel as well as a trackpad, the filter finds things by other names too ("firewood", "zabuton"; in
  Japanese, hiragana or katakana), and the Eraser's sweep leaves made things, wood and boulders alone (a
  click takes one).
- A garden and a workplace to fill it: a wooden fence laid by dragging (a post every 2.5 units, rails
  following the land, its end joining a fence's near it into one run; ⌥ lays it straight, a click a short one,
  and Return at each corner lays one with the keys), with Straighten and Add Gate on its bar; a flower pot, a
  planter box, a watering can, a birdhouse and a straw beehive; a low writing desk, a bookshelf, a bench, a
  signpost, a mailbox, a noticeboard, a garden shed and a canvas tent. Made things with colours to choose (the
  bench, the shed's door, the tent, the pot, the cushion, the cat's bed and more) show them on the selection
  bar's Colour button, in the blankets' own gingham shades; the next one placed wears the colour you chose last.
- Garden lamps for the meadow (Edit Meadow › Garden): a lamp post that lights by itself after sunset and
  goes out after sunrise, the lamps coming on one by one with a little stutter as each catches. Lit, each
  pools warm light on the grass round it, lights what stands near it and the rain or snow falling past it, and
  glows softly, more so in fog. Placing one at night shows its light before it is put down. At most 32; never
  on the picnic ground. Settings › Meadow › Lamps light at night turns them off.
- Painted paths now read as pale, dry, trodden earth with a few pebbles and short tufts along their sides,
  and soil as a dark tilled bed in ridges, so the two are told apart at a glance; the earth's flecks are
  soft and round instead of small blocks.
- My Meadows (Settings › Meadow, and My Meadows… in the editor's name menu): a card for every meadow, the
  Default first, each with a picture of it drawn by the meadow itself and what it holds ("214 things · paths
  and lawn"); click to use one; Rename in place, Duplicate, Show in Finder, Move to Trash (asking first), and
  New Meadow from the Default or empty.
- Meadows as files to share: Export… (with your name and a line about it, if you like), Share…, or drag a card
  to the Finder; Export Picture… for a post. A meadow file holds the scenery only: nothing of your Mac, your
  folders, your workspaces, the date or you. Open one with a double-click, File › Import Meadow…, or by
  dropping it on the meadow, My Meadows or the Dock icon: the import sheet shows it drawn, who made it, what it
  holds and what to know, and Add or Add and Use never replaces a meadow of yours. A file from a newer Whiskr
  opens and keeps what this one cannot show; one too new, damaged or too large says why and what to do.
  Meadow files have their own icon in the Finder.
- Things a newer Whiskr put in a meadow show as parcels while editing, to be moved or taken away, and are
  never lost on save.
- A meadow changed on disk by something else (a sync tool, the Finder) is read again; while you edit it,
  you choose Keep Mine or Reload, and the other version is kept as a meadow of its own.
- Trees and the fallen log make way where a blanket comes, as flowers and stones always did, and come back
  when it goes. The workspaces' column always runs down the middle of the meadow.
- The meadow's sky follows the real sun: dawn, day, dusk and night come at the real sunrise and sunset
  where you are (from where real weather found you, or from your time zone; worked out on your Mac and
  never asking), through the polar day and night too. Settings › Meadow shows today's sunrise and
  sunset, and refreshes when the day or the time zone changes. The moon is the real one (its phase, its
  lit edge toward the sun, rising and setting), and full-moon nights are a little lighter. With the view
  tilted down as far as it goes, the moon and a field of stars show in the sky over the far hills.
- Real weather shows the wind's direction and gusts in the grass, flowers, seeds and rain, rain and snow
  from light to heavy, haze when visibility is poor, and soft, rare sheet lightning in a thunderstorm
  (never with Reduce Motion or the animation off). Each of these, the clouds, the grass's colour from the
  temperature, the real sun and the moon's phase has its own switch in Settings › Meadow; the weather is
  still one request to Open-Meteo every 15 minutes.
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
- Files and Changes beside the terminals. A light editor with find and replace and Go to Line. Markdown,
  image and PDF previews. Diffs side by side or inline. Staging, discarding and committing.
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
  lists them all, and "+" stays in reach. The tab row begins with the workspace's colour and name, whose
  menu lists every workspace.
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
  editor ⌥↑ ⌥↓ move lines, ⇧⌥↑ ⇧⌥↓ copy them, ⇧⌘K deletes them, ⇧⌘\ goes to the matching bracket and
  ⌃G goes to a line. File › Save All (⌥⌘S). Terminals still receive these keys.
- The editor closes brackets and quotes as VS Code does (and types over them, and wraps a selection), boxes
  the matching bracket, shows indent guides and tints other occurrences of the word at the cursor.
  Settings › Editor: indent with spaces or tabs, and trim trailing whitespace and insert a final newline on
  save. A repository's `.editorconfig` is followed.
- English and Japanese throughout, following the system language.
- Upgrading from the app's earlier working name, "Workers Factory": at first launch, its settings, saved
  layout, the Claudes' last state and themes are carried over. Its git worktree folder
  (`~/.workers-factory`) becomes `~/.whiskr` when it holds no checkout; checkouts stay where they are. A
  session host the old app left running is never stopped, and its terminals are counted and left alone.

- Settings › Alerts: for each event (permission request, question, finished, error, helper finished, a
  terminal's bell) its sound (Whiskr's, the Mac's, one of your own files, or none) and whether it
  notifies, each with Play; a volume; sounds only while Whiskr is in the background; and whether macOS
  lets Whiskr's notifications through, with a way to turn them on.
- The meadow follows what you choose on the right: a workspace, tab or pane chosen by click, key, menu,
  Go to or ⌃Tab glides its blanket and its cat into view (once a quick run of choices has stopped, and
  not at all when it is already in view). The cat of the terminal you are in is marked by a soft pool of
  light and a ring. Nothing an agent does moves the view, and once you move it yourself it stays until
  you choose something else.
- The interface moves on one small set of timings: tabs open out, close by folding as their neighbours
  slide over, and move when dragged, with the selected tab's mark sliding to the tab you choose; Go to
  opens out of the top bar's field and closes the same way; the ⌃Tab list, the find bar, the worktree
  panel and Home's note fade; going Home and back cross-fades; the side panel and the status bar slide.
  The action never waits for the picture, and with Reduce Motion things fade instead of moving.
- The workspace menu starts with New Workspace (⌘N) and Open Folder… (⌘O).
- Theme previews show the theme's sixteen terminal colours and its selection colour.
- A tab split into panes shows one segment per pane in the tab row, joined into one tab as Chrome draws a
  split view: each with its pane's icon, title and state, and its own close button. A click on a segment
  shows that pane with the keyboard; its ×, a middle click or Close Pane in its menu closes that pane
  alone. Close Tab, which names how many panes it closes, closes them all. In a tight row a split tab keeps
  its focused pane's title and shows the others as icons before any tab goes out of sight. A name given
  to a split tab leads its segments as a small label.
- In a tab of several panes every pane has a header (terminals too) with Zoom Pane and Close Pane. The
  pane you type in has its header tinted with the accent and underlined in it; the others fade a little.
  The line between panes is the theme's strong separator, at least 1.5:1 on the content in every theme.
- "+" sits right after the last tab, as in Chrome, and moves with the tabs.
- Dragging a tab picks it up: it hangs from the pointer where you grabbed it, a little lifted, trailing on
  a spring and swinging slightly with its speed. Before you let go the window shows what a drop will do:
  the other tabs part where it would land, a tinted area over a pane is exactly the half it would take
  ("Split Right", "Split Down"…) or the whole pane ("Move Here"), and another workspace's blanket is
  marked ("Move to “name”"). Anywhere else it fades, and let go there (or Esc) it springs back.
- Graphite, a built-in dark theme of neutral near-black greys with no colour cast, soft white text and a
  restrained blue.

### Fixed

- Cats keep their eyes round whenever they are awake: no more half-shut look while washing, stretching,
  nibbling, sipping tea, lying as a loaf or in a gust of wind. They still blink, shut their eyes to sleep
  (closing them in one movement as they doze off) and squeeze them shut when petted.

- Leaving the meadow's editor with the workspaces shown as a list gives the keyboard back to where it was
  every time: it is handed back once the terminals' region has finished opening, which used to take it away
  again as it settled.
- A click on a button of the top bar, tab row or status bar right after the bars changed (a tab opened,
  closed or dropped) could be taken by the view drawn over it and do nothing.
- A tab's to-do ring sometimes did nothing when clicked: right after its list had closed (the click was
  taken as closing a list already gone), or a frame after a pane closed (the tab took the click). The ring
  is now clicked where the tab's other clicks are, at once where the tab is; a click while the list is
  closing opens it again, and a click on the ring with the list up closes it. Its hover fill now shows on
  the selected tab too.
- The close button on a split tab, which showed only the focused pane's name, closed every pane in the tab.
- New Workspace (⌘N, the File menu, the "+" and workspace menus, the command palette) did nothing on Home:
  there it now starts a terminal in a new workspace, as Home's New Terminal does.
- ⌘Z after closing a pane put the tab back as it was before, dropping any pane opened in it since.
- The hint under the meadow ("Type claude in a terminal…"), Home's line on where cats come from and its
  "Or drop a folder here." are gone; Home keeps its actions.

- The workspace button in the tab row did nothing when clicked, nor did Home's place button, the top
  bar's "+" or the tab row's list of tabs: each now opens its menu as it is pressed, under it, as a pop-up
  button does. Every control in the bars shows its hover and pressed fills, and pressing one never moves
  the window.
- Alert sounds were never heard while you watched the Claude you had typed to, or while you were in
  another app, and notifications never appeared: macOS was asked once and its answer never looked at
  again.
- Dragging a divider left a blue line where the drag began; the highlight now moves with the divider and
  goes when the pointer leaves. The side panel's edge no longer lights with the pointer over the panes,
  and a pane divider's highlight is one 3 pt line, not two stripes.
- While a dark-only theme such as Nord was chosen, Settings showed the themes that have a light version
  dark; each preview now shows its theme as it will look once chosen.
- With a light theme, the terminal told programs that ask (`CSI ? 996 n`) that it was dark.
- The pointer on one tab showed every tab's close button.
- Clicking a terminal in a split gives it the keyboard; Show Workspaces as List scrolls to the workspace
  you choose.
- A terminal no longer stretches for a moment as it takes a new size.
- After a divider was dragged, a terminal could go back to its size from before the drag, its program
  told the old size.
- Hiding and showing the meadow or the terminals could resize the window (even to nothing) instead of
  sharing it between them, and quick toggles could leave the regions no longer following the window.
- A region's slide that never finished (in a window out of sight) no longer leaves terminals at their old
  size.
- Undo Revert Change works after its diff has closed or been replaced (a preview tab gives way to the next
  file chosen in Changes); it did nothing, and the reverted lines were lost.
- A file opened through a link (`CLAUDE.md` pointing at `AGENTS.md`) reloads when Claude edits it.
- A damaged `.vsix` can no longer quit the app, and one that unpacks to far more than it says is stopped.
- A repository's `.editorconfig` with braces nested very deep no longer quits the app on opening a file.
- Deleting a theme removes only its own copy of the files it was imported from, to the Trash; a shared
  theme file can no longer name another folder to be deleted.
- A theme whose id differs from another's only in case or spaces no longer replaces that theme's file.
- A grammar whose capture includes itself, or with an expression nested hundreds deep, no longer quits
  the app (and the files that reopen at launch with it).
- Files with Windows line breaks (CRLF) show their diffs line by line, and Stage, Unstage and Revert Change
  work on them.
- Stage and Revert Change put the change in its place whatever your git settings (`diff.context=0`,
  `diff.mnemonicPrefix`); added, deleted, renamed and submodule files are staged or reverted whole, from
  Changes.
- Stage and Revert Change act only on the change they were shown for, even after the diff reloads under
  the pointer; Undo Revert Change can be redone and undone again, and the note's Undo undoes that revert.
- A `file:` link in a terminal opens in the editor (or beeps), and is never handed to macOS to run.
- Wrap Lines no longer has ⌥Z: it took "Ω" and, on a Polish keyboard, "ż" from typing in the editor.
- A language's bracket pair with an empty side no longer freezes typing.
- Typing in a line longer than 500 characters leaves its colours to the background, instead of stalling
  the window in some grammars.
- Colours guessed for a far part of a file no longer stay after an edit above it.
- Importing a theme that includes the same files over and over, or a .vsix, no longer freezes the window:
  a .vsix is unpacked once, off the main thread, and one that would unpack to more than 256 MB is refused.
- An `.editorconfig` section with many `*` no longer freezes saving.
- Import Settings no longer quits on a tab size or font size such as `1e300` or `"nan"`.
- A folder with "#" or "?" in its name is followed correctly by the terminal (bash, zsh and fish), and
  bash with `set -u` no longer complains at every command.
- A refused patch can no longer end the app while git is reading it.
- Previous and Next Command stay available in every terminal.
- Move Line, Delete Line and Tidy on Save treat a line holding U+2028 or U+0085 as one line.
- A language chosen in the status bar stays when languages are added or removed.
- A save that fails leaves the text untidied, as it was.
- Files and editing: ⌘-click on a path, or Go to with a line (`:42`, `name:42`), now goes to the line in a
  file that is already open; it only worked when the file was opened anew. A file deleted outside the app
  says so in a repository under a linked folder (`/tmp`) too, and the bar goes again if the file comes
  back as it was. After Keep Mine, the bar comes back only for a further change to the file, not for any
  change in its folder. Don't Save no longer leaves the discarded changes waiting in the file opened
  again. The status bar's line and column follow the tab shown. Show Preview (⌥⌘P, ⇧⌘V) from side by
  side shows the preview, as it says, not the source.
- Diffs and Changes: a diff no longer crashes the app when its pane widens enough to go from inline to
  side by side. ⌘Z after a commit no longer reaches into the cleared message field (it could crash the
  app); the message keeps an undo of its own. After Redo of Revert Change, Undo puts the change back
  again. A new picture's diff says it is binary rather than "No changes".
- A path whose folders have brackets, as web frameworks name routes (`app/[id]/page.tsx`,
  `app/(shop)/page.tsx`), is a link in the terminal. A picture a Markdown file names before it exists
  shows once it is made.
- Resting the pointer on a tab's close button could quit the app when its tooltip came up.
- ⌘Z brings back the one tab closed last. After a closed tab's ten seconds ran out, the next ⌘Z brought
  back every tab closed lately at once, and showed the wrong one.
- Closing the tab of a Claude that was waiting on you takes its count off the Dock badge.
- After renaming a tab or a workspace (Return or Esc), the keyboard is back in the terminal, and a second
  rename takes the keyboard as the first did.
- Clicks on the cats and blankets reach them anywhere in the meadow: the "↓ 1 need you" capsules no
  longer lie over the whole meadow, and clicking one leaves the keyboard in the terminal.
- A Claude whose error you have looked at shows as idle at once, not working for a moment more; a prompt
  typed straight after an error shows it thinking.
- ⌘J at the only request goes back where you were, instead of staying put.
- Notifications are asked for when a Claude first gets to work in one of the app's terminals. They were
  never asked for, so requests' notifications with Allow and Deny never appeared.

- Files and Changes no longer vanish when switched quickly: showing the panel again while it was still
  sliding shut (⇧⌘E, then ⇧⌘C at once) left it hidden though its button said it was open.
- In a narrow window the status bar lets go of the ⌘P and ⇧⌘P hints, then the folder, instead of cutting
  every item short ("fe…ut", "5 Claud…").
- A flag short of room shows a branch's own name, "…/checkout", rather than cutting it in the middle.
- Show Workspaces as List draws in the theme's colours, with each workspace's name stronger than its
  folder (the names were the fainter of the two).
- Help: "Terminals keep running" (the page said "sessions"), and the states without a mark line up with
  the others.
- The changed-files count on the panel button stays inside the button, clear of Settings.
- A saved layout the app cannot read (damaged, cut short, or written by a newer version) is no longer
  replaced by the next launch's: it is kept beside it as `layout-unreadable-<time>.json`.
- Closed tabs no longer stay in memory after their ten seconds of ⌘Z: the last ten were kept whole, with
  their terminals' views and scrollback, though Reopen Closed Tab needs only their folders.
- `paw run` on a busy Mac no longer hands a helper its task before the program has had its say: a
  program slow to start, or a report not yet read, could be taken for ready, and the task typed into a
  question it was asking.
- The meadow at rest costs less: a change in it (a cat dozing off, a lantern going out) no longer draws
  at the display's full rate for the next few seconds as if you had touched it; it is drawn at a calm
  30 frames a second when nothing in it moves fast, and it goes back to its slow resting tick sooner.
  Day and night idle alike.
- The first file opened after launch no longer catches the window for a moment while macOS sets up the
  text cursor's helper; that is done during launch.
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
