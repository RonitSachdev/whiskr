# Architecture

How Whiskr is put together: its processes, its modules, how Claude's state reaches the meadow, and what it
keeps on disk. For what the app should look and feel like, see [DESIGN.md](DESIGN.md).

## Processes

```
 Whiskr.app (the window)                       whiskr-host (session host)
 ┌───────────────────────────────┐   Unix     ┌──────────────────────────────┐
 │ Workbench (model)             │  socket    │ one pseudo-terminal per      │
 │ meadow (MeadowScene, Metal)   │◀──────────▶│ terminal; your shell, claude,│
 │ panes (SwiftTerm views)       │ one link   │ any program                  │
 │ hook listener 127.0.0.1:port  │ per pane + │ keeps 4 MiB of output each   │
 └──────────────▲────────────────┘ one for app└──────────────┬───────────────┘
                │ HTTP POST (curl, from Claude Code's hooks)  │ paw (in any terminal)
                └─────────────────────────────────────────────┘
```

- **The app** is a client. It draws the window, keeps the model of workspaces, tabs, panes and Claudes,
  and renders the meadow.
- **The session host** (`whiskr-host`, inside the app bundle) owns every terminal. The app starts it on
  demand as a detached process in a session of its own, holding none of the app's descriptors. Quitting,
  crashing or replacing the app therefore leaves it and every program running. There is no launchd agent
  or login item. With no terminal running and no client connected for 30 seconds it exits by itself. On
  SIGTERM (logout, shutdown) it ends its terminals first.
- **`paw`** (also inside the bundle, linked onto every pane's PATH) talks to the same host, so programs in
  one terminal can start and steer others.

## Modules

| Module | Where | Depends on | Holds |
|---|---|---|---|
| `Whiskr` (app target) | `native/App/Whiskr` | everything below, SwiftTerm | AppKit/SwiftUI window, menus, panes, files and editor views, the hook listener, notifications, the `Workbench` model |
| `WhiskrKit` | `native/App/WhiskrKit/Sources/WhiskrKit` | Foundation, COniguruma | Logic with no UI: agent states from hook events, the story of a helper, layout and its saved form, themes and VS Code theme import, the TextMate grammar engine and language registry, EditorConfig, the key table, file icons' mapping, Markdown parser, diffs and their folds and one-change patches, git status and worktrees, the host protocol, fuzzy ranking and Go to's queries, ⌃Tab's order, command marks, links in terminal output, `LegacyMigration` |
| `TerminalHost` | `…/Sources/TerminalHost` | WhiskrKit | The host server, pseudo-terminals, the client connection, the launcher |
| `Paw` / `PawTool` | `…/Sources/Paw`, `…/Sources/PawTool` | TerminalHost | The `paw` command-line tool and its `main` |
| `WhiskrMeadow` | `…/Sources/WhiskrMeadow` | WhiskrKit, MeadowScene | Maps the app's snapshot of workspaces and Claudes to the scene's world |
| `MeadowScene` | `native/Scene` | Metal, AppKit | The meadow, cats, props, camera and a small Metal renderer (`MeadowView`); `MeadowDemo` is a standalone viewer |
| `COniguruma` | `…/Sources/COniguruma` | libc | Oniguruma 6.9.10, vendored unchanged (BSD-2-Clause), the regular expressions TextMate grammars are written for; built optimised in Debug too (`Packages.xcconfig`) |
| `WhiskrHost` (tool target) | `native/App/WhiskrHost` | TerminalHost | The host's `main` |

`WhiskrKit` stays free of AppKit and Metal so its tests run in seconds with `swift test`.

## How Claude's state reaches the meadow

1. **Shell integration** (`ShellIntegration`). Each pane's environment puts a folder first on PATH. That
   folder holds a `claude` shim and a link to `paw`. zsh is pointed at a `ZDOTDIR` of ours that hands
   straight back to the user's own startup files and re-asserts PATH before every prompt. fish gets a
   `vendor_conf.d` script, and bash a `PROMPT_COMMAND` that reads `shell/bash/whiskr.bash` once per
   shell. None of the user's files are written.
2. **The shim** runs the real Claude Code with `--settings <hooks file>`. The hooks are command hooks
   that `curl` each event to the app's listener. They read the listener's address, at the moment they
   fire, from a per-pane file that each launch rewrites. With no app running they do nothing and never
   fail.
   Your own `--settings` (a file or inline JSON) is merged with the pane's hooks by `paw merge-settings`
   into a 0600 `merged-<hash>.json` in the hooks folder (cleared at each launch), and that path is passed;
   the shim stops looking at `--`. When the merge cannot be done, your settings go through untouched and one
   line on stderr says the app will not see the session.
3. **The listener** (`HookServer`) accepts only 127.0.0.1, checks a per-launch secret, answers "no opinion"
   at once, and hands the event to `AgentMonitor`, which turns events into states (`AgentWorld` in the
   Kit).
4. **Before any hook**, the host watches each terminal's foreground process group ten times a second while
   a window is connected. A cat appears as soon as `claude` is the foreground program.
5. The `Workbench` builds a `SceneSnapshot`, `WhiskrMeadow` maps it to the scene's `World`, and
   `MeadowView` animates the difference. A selection reaches the scene with its origin
   (`MeadowView.select(_:origin:)`): `.user` when `Workbench.choices`, counted only for the user's own
   choosing, has moved, which makes the camera follow (`Stage.follow` on `MapCamera.chase`); `.event`
   otherwise, which only moves the ring.

Helpers' own conversations are read from Claude Code's transcript files, because hooks do not carry them.

## What the shell tells a terminal

Before each prompt the shell integration also writes, for every shell:

- **Where it is** (OSC 7), which names the workspace and the tab and tells the app the prompt is up.
- **Command marks** (OSC 133, as Terminal, iTerm2, VS Code and Ghostty read them): `A` as a prompt is
  drawn, `C` as a command starts, `D;<status>` when it has ended. The app uses them to go between
  commands, to select a command's output (`CommandMarks`, in the Kit) and to light a lantern red. zsh
  and fish before 4 write all three; fish 4 writes them itself. bash adds a zero-width `B` at the end of
  `PS1`, where the typed command begins; bash 4.4 and later also writes `C` (from `PS0`) and `D`, but
  the bash macOS ships (3.2) has no `PS0`, so it marks prompts only. The marks are printed before the
  prompt, never put into it, and are left out when something of the user's writes them already (iTerm2's
  integration, a prompt theme such as Powerlevel10k, a hook): two sets would count every command twice.

SwiftTerm keeps a view's `Terminal` and `SelectionService` internal, though both types are public. The
command marks, the buffer's lines and setting a selection need them, so `TerminalReach` finds the two
stored properties by reflection, once per terminal, and reads or sets them holding the terminal's lock.
It is the only place that does this. If a SwiftTerm update renames them, nothing is found and the
features that need them dim in the menus; nothing else changes.

**Links in output** (`TerminalLinks`, in the Kit, tested) are found on the line under the pointer, joined
with the rows it wrapped onto: web links, and paths by their look (a `/`, or a name with an extension),
with a line and column in the forms compilers, test runners and `grep -n` print. A path is resolved
against the pane's folder, trying it without git's diff prefixes (`a/`, `b/`…) first; only one that
exists is underlined or opened.

## The session host protocol

`HostProtocol` and `HostFrame` (in the Kit) work over any ordered byte stream. A frame is a 4-byte length,
a kind byte and a payload. Requests, answers and events are JSON. Terminal output and keystrokes are raw
bytes, never inside JSON.

- **Versions.** `hello` and the framing never change. Each side states the newest protocol it speaks and
  the oldest it still understands, and they talk when the ranges overlap. A host the app cannot talk to is
  never ended: the app starts its own beside it (`host-v<n>.sock`) and says how many terminals the other
  holds. Unknown frame kinds, requests and events are skipped, not fatal.
- **Version 1:** create, attach, detach, resize, redraw, signal, close (after a delay, for undo), keep,
  list, shutdown; events `status` and `exited`.
- **Version 2:** terminal addresses (`t1`, `t2`…) and names, `run`, `send`, `keys`, `interrupt`, `wait`,
  `read`, `subscribe`; events `added` and `passed`; programs' own status reports (OSC 7501), which the host
  reads and answers.
- **Output in as few pieces as keep its order.** A pseudo-terminal gives at most a kilobyte a read on
  macOS. The host joins what one pass reads into one frame, and the app joins consecutive frames for the
  same terminal that arrive in one socket read, up to 64 KB (`OutputBatch`). Nothing waits to be joined,
  so a lone echo goes at once; a flood costs the terminal's lock, which typing and drawing also take,
  far fewer times.
- **One connection per pane**, each read on its own thread, plus one for the app. The client's socket is
  non-blocking (macOS ignores `MSG_DONTWAIT` on a blocking Unix socket), so a large paste never holds up
  the window. A viewer that cannot keep up stops the host reading that terminal (backpressure) instead of
  filling memory.
- **Reattaching.** The host keeps each terminal's latest 4 MiB of output. When older output is dropped, it
  first restores the terminal modes the program had set (alternate screen, bracketed paste, mouse and
  focus reports, keyboard protocol, cursor) and asks the program to redraw. Output printed at an earlier
  size is replayed at that size.
- **Sizes.** A new terminal starts at the size its view first takes in the window, in the turn the view is
  laid out. A resize reaches the program only after the size has held still for 80 ms. During a live
  drag (a divider, the window's edge, a region sliding), terminals keep their size and take the new one
  once at the end: a re-wrap costs about 3.4 ms per terminal with 12,000 lines (measured, `make perf`'s
  resize run), times every pane on every step, and each size would reach the program. The pane around a
  held terminal shows the terminal's background, and a Metal frame drawn for the old size is pinned at the
  top left (`layerContentsPlacement`), never stretched, until the next is drawn. To SwiftTerm a terminal is
  never in a live resize (it would apply a size held for its next frame after a later one). Region slides
  (the meadow, the side panel, the status bar) go through `LiveResize.slide`, held until the animation's
  completion or at the latest half a second after its duration, so a slide in a window that does not draw
  cannot freeze terminal sizes; a layout change during a slide is applied at once and the slide's end
  applies the layout again. The window's regions share its width
  (`preferResizingSiblingsWithFixedSplitView`): opening or closing one never resizes the window.

## Files on disk

| Where | What | Notes |
|---|---|---|
| `~/Library/Application Support/Whiskr/layout.json` | Workspaces, tabs, panes, their folders, the host terminal each pane shows | Written on changes and on quit. Which workspace was selected is not kept: a launch lands on Home. One a launch cannot read is kept as `layout-unreadable-<time>.json` |
| `…/Whiskr/agents.json` | The Claudes' last known state | So cats come back as they were after a relaunch |
| `…/Whiskr/Themes/*.whiskrtheme` | The user's own and imported themes (plain JSON) | An imported VS Code theme is stored in Whiskr's form, with its `tokenColors` |
| `…/Whiskr/Themes/Originals/<source>/` | The files an imported theme was read from (theme JSON and what it includes, or an extension's `package.json` and theme files) | Kept so a later version can import them again; moved to the Trash with the last theme made from them (only a folder directly in `Originals`: a theme file names its folder, and anyone can write one) |
| `…/Whiskr/Languages/<set>/` | Languages and grammars the user added: an `index.json` and the grammar and configuration files, copied as data | Loaded at launch over the bundled ones (`LanguageRegistry.loadInstalled`); nothing in them is ever run |
| `…/Whiskr/shell/` | The shim, zsh, bash and fish integration | Rewritten at every launch |
| `…/Whiskr/Sounds/` | Sounds added in Settings › Alerts, copied in as they are | A missing one falls back to its event's default sound |
| `…/Whiskr/hooks/` | The hooks settings and each pane's listener address | Mode 0700, files 0600; rewritten at every launch |
| `…/Whiskr/host/` | The host's socket, lock and log | Mode 0700, socket 0600 |
| `~/.whiskr/worktrees/<repo>/<branch>` | Git worktrees the app makes | Changeable in Settings › General |
| User defaults `app.whiskr.Whiskr` | Settings, recent folders, window layout | |

Debug builds run with `--isolated <folder>` keep all of this inside that folder, with their own defaults
suite and their own host.

## Highlighting

Code is coloured from TextMate grammars, the format VS Code and its extensions use, by an engine of our own
in the Kit, so a file colours as people are used to and an imported VS Code theme colours it exactly as VS
Code does.

- **Languages** (`LanguageRegistry`, `CodeLanguage`). A bundled index (`WhiskrKit/Sources/WhiskrKit/Languages`,
  made by `Scripts/update-languages.py` from the pinned list in `Scripts/update-languages.json`) holds each
  language's names, file names, extensions, path patterns and first-line pattern as VS Code's extensions
  contribute them, its `language-configuration.json` (comments, brackets, closing pairs, indentation and
  Enter rules, `offSide`), and its grammars. A file's language is found as VS Code finds it: its whole name,
  then the longest path pattern, then the longest extension, then its first line, else plain text; the one
  registered last wins a tie, so what a person adds beats the bundle. Grammars are read only when a file of
  their language opens, and compiled once per language off the main thread (`GrammarStore`).
- **The engine** (`TextMateGrammar`, `TextMateTokenizer`, `TextMateRegex`): a translation of
  vscode-textmate (rules, includes, injections with their priorities and file order, begin/end and
  begin/while, captures with patterns, back-references, `\G`, the endless-loop guards) over Oniguruma, searched
  in UTF-8 as VS Code does, with offsets given back in UTF-16. A line's end state is an immutable rule stack,
  cheap to compare. Lines longer than 20,000 UTF-16 units are not tokenised (their state carries over), and
  each line has a time and backtracking limit. Captures tokenised again nest at most 16 deep, and an
  expression's groups at most 200 (Oniguruma parses recursively, on 512 KB background stacks).
- **Incremental, off the main thread** (`SyntaxStates`, `BackgroundTokenizer`, `DocumentSyntax`). Each line
  keeps the state it starts in and its tokens. An edit is tokenised on the main thread for at most 3 ms,
  from its first line until a line ends in the state it ended in before, and only lines of up to 500 units
  (one search's cost grows with the square of its line, and the time limit holds only between searches);
  the rest goes to a serial queue that hands back 8 ms stretches. Lines keep their old colours until new
  ones arrive, and lines shown far ahead of the background pass with no colours yet get a provisional pass
  from a guessed start first. The main thread never waits for tokens.
- **Colours** (`SyntaxTheme`, a translation of vscode-textmate's theme). A token is its range and an interned
  scope stack; its style (foreground, background, italic, bold, underline, strikethrough) comes from the
  theme's scope rules by TextMate's selector matching with specificity and parent scopes, cached per stack, so
  a theme change needs no tokenising. An imported VS Code theme's `tokenColors` are used as they are; a theme
  without them (Whiskr's own, the terminal palettes, iTerm2 imports) gets rules made from its terminal's ANSI
  colours, each kept at 3:1 on the background.
- **Drawing.** Only lines near the visible part are coloured, as TextKit 2 rendering attributes, which need
  no layout. Bold and italic change glyphs, so they come from the content storage's paragraphs
  (`SyntaxParagraphs`), rebuilt only on screen and a few lines per run-loop turn. The Markdown preview's code
  blocks and the diff view use the same engine and theme, tokenised off the main thread.
- **Added languages.** File › Import Themes and Languages… (or Settings' Add Theme…) takes a `.tmLanguage.json`
  or `.tmLanguage` grammar, an extension folder or a `.vsix`; only `contributes.languages` and
  `contributes.grammars` are read, and their files are copied into the support folder.
- **The first screen before the first layout.** While a file is read (off the main thread), its grammar is
  compiled and its first 160 lines are tokenised (at most 25 ms), so the text is laid out once, already in its
  colours and italics, instead of plain and then again. A file whose lines are too long to colour skips this.
  The editor font's four faces (and the fonts Core Text falls back to for arrows, ellipses and Japanese) are
  drawn once off the main thread as the first file opens (`EditorStyle.warmFonts`): Core Text reads a face's
  tables the first time it draws with it, which held the main thread 30–55 ms in about a third of opens.
  AppKit's text-cursor helper (the input-source indicator by the caret: it loads `TextInputUIMacHelper` and
  makes a hidden window, 18–30 ms on the main thread, once per process) is set up during launch, while
  launch waits on the session host (`AppDelegate`), not when the first file's caret is placed.
- **The language of one file** can be chosen from the status bar's language item (as in VS Code); the choice
  holds for that path while the app runs, and Auto Detect goes back to the detected one.
- **Lines too long to edit.** TextKit lays a paragraph out again whole on each keystroke in it (about 0.17 ms
  per thousand characters), so a line over 80,000 UTF-16 units (`FileDocument.longLineEditLimit`) is kept from
  being edited, with a bar saying so and Edit Anyway; the rest of the file edits as usual. While the cursor is in
  such a line the text view is not editable, so it has no caret: AppKit places a caret by reading its whole
  paragraph on every layout (it doubled scrolling there). Measured on a 2 MB minified line: a refused key
  0.02 ms, a key after Edit Anyway about 330 ms (TextKit's floor). Wrapping off is no help: TextKit then lays the
  line out as one, slower still.
- **Nothing narrows the text after it is laid out.** The gutter's width (room for the largest line number) and
  the page's bar are set before the text's first layout; set later, a wrapped line is laid out again (a
  minified file's took 300 ms more to open).

## Themes, icons, keys and EditorConfig from VS Code

- **Themes** (`VSCodeTheme`, `ThemeImport`, `ThemeGuarantees`). A VS Code colour theme (`.json`/`.jsonc`,
  a legacy `.tmTheme`, or the themes an extension folder or `.vsix` contributes) is read as VS Code reads it:
  `include` chains, `colors` merged child over parent, `tokenColors` parent first, "default" values, colours
  with alpha blended over the layer they are drawn on. Its workbench colours map to Whiskr's keys (content from
  `editor.background`; the chrome from the first of the title bar, tab header, side bar, inactive tab, status
  bar and panel colours that is a step below it; lines from the border colours; the accent from
  `tab.activeBorderTop` or `focusBorder`; the sixteen terminal colours, with VS Code's own defaults for the
  theme's kind when absent; the editor's and git's and the diff's colours, `ThemeEditorColors`). Then
  `meetingGuarantees()` moves, in 1 % steps, only what falls short of the layer and contrast guarantees
  (DESIGN.md, "Layers"). Themes of one extension whose names differ only by "Light" and "Dark" become one
  theme with both versions; two single themes can be paired by hand. Which version applies has one rule,
  `Theme.isDark(following:)`: a theme with one version decides, else the app follows the Mac's appearance
  (`ThemeStore.systemIsDark`, read from macOS, since the app's own cannot tell it while a one-version theme
  holds it). A theme's card in Settings draws `ThemePreviewColors` (Kit), the colours the terminal and the
  window will have once it is chosen, and the terminal is told the theme's light or dark
  (`updateColorScheme`, for programs that ask).
- **Settings from VS Code or Cursor** (`VSCodeSettings`, `OtherEditorImport`): on request only, their
  `settings.json` is read (never written), and the editor and terminal font, size, indentation, wrapping,
  invisibles, save fixes, cursor and the colour theme (imported from the extension on disk when it is not a
  built-in) are applied. Isolated runs read `<isolated>/Home` instead of the home folder.
- **File icons** (`FileIconTheme` in the Kit, `FileIcon` in the app): VS Code's Seti icon theme, its mapping
  (`seti.json`) and font (`seti.woff`, read by Core Text, never installed), looked up as VS Code does: the
  file's name, then its extensions longest first, then its language, then the default. Each glyph is drawn
  once per size into a template image, so it takes the text's colour in either appearance.
- **Keys** (`KeyTable`, `ScopedKeys`): every key the app has, with the rules that keep them apart, checked by
  a test and, against the live menus, by `--script keytable`. A menu item can carry one key; a second one
  (VS Code's) is a hidden item. A key without ⌘ that only the editor uses is scoped to it, so a terminal still
  receives it.
- **EditorConfig** (`EditorConfig`): the `.editorconfig` files above a file, nearest first until `root =
  true`, decide its indentation when it opens and its trimming, final newline, line endings and encoding when
  it is saved.

## Identifiers

| What | Identifier |
|---|---|
| App bundle | `app.whiskr.Whiskr` |
| Session host | `app.whiskr.Whiskr.host` (executable `whiskr-host`) |
| `paw` | `app.whiskr.Whiskr.paw` |
| Theme file type | `app.whiskr.theme` (`.whiskrtheme`) |
| Pane environment | `WHISKR_PANE`, `WHISKR_BIN`, `WHISKR_HOOKS`, `WHISKR_ZDOTDIR`, `WHISKR_XDG_DATA_DIRS`, `PAW_ID`, `PAW_SOCKET`, `PAW_PARENT`, `PAW_NAME`, `PAW_WORKTREES`, `PAW_TASK` (a `paw run` task on its way to Claude); `TERM_PROGRAM=Whiskr` |

## git

git runs off the main thread, as an argument list, never through a shell. Paths are always given
literally (`GIT_LITERAL_PATHSPECS`, only for commands given paths, so a repository's own hooks keep their
patterns): a name holding `[`, `*` or `?` never matches other files. Pipes to every child process are
close-on-exec (`ProcessPipe`), so no other child keeps one open. One change of a diff is staged, unstaged
or reverted by `git apply` of a patch of that change alone (`DiffPatch`), on stdin.

## Launching

A launch brings every workspace back and selects none: the window opens on Home, once the layout is
restored (or after a second, if the session host is slow to start), so it never shows an empty Home that
fills in. Each saved pane is decided by `ResumePlan` (in the Kit, tested):

- the session host still holds its terminal: it is attached, screen and process as they were, and
  nothing is typed;
- otherwise a fresh shell starts in its folder, and nothing is typed, except for a pane that ran Claude:
  that one types `claude --resume <id>` (Settings › Resume Claude in restored panes);
- never while another version's host, or the earlier-named app's, still holds terminals: those Claudes may
  be alive there, and a resume would start a second Claude on the same conversation. The bar on Home
  about the other version's terminals then says how many Claudes were not resumed.

A terminal the host holds that no pane claims joins its folder's workspace without being selected.

## Migration from the earlier name

Until November 2026 the app was developed as "Workers Factory" (bundle `dev.workersfactory.mac`). At launch,
before anything reads settings, `AppMigration` runs `LegacyMigration` (in the Kit, tested against scratch
folders) once:

- **Settings:** the old defaults domain is copied into Whiskr's when Whiskr has none. The old built-in
  theme's id is renamed. The "notifications requested" flag is dropped, because notification permission
  belongs to a bundle identifier and must be asked for again.
- **Support folder:** `layout.json`, `agents.json` and `Themes/` go to `~/Library/Application
  Support/Whiskr` when it does not exist yet. They are assembled in a staging folder and renamed into
  place, so an interrupted launch leaves nothing half-made. They are **moved**, unless the old app or a
  session host it started is still running, in which case they are **copied**: that host's terminals use
  the old folder's shell integration and hook files. Everything else in the old folder is regenerated by
  Whiskr and stays where it was. Old `.wftheme` files are renamed to `.whiskrtheme`, and the old theme
  format is still read.
- **`~/.workers-factory`** becomes `~/.whiskr` when it holds no git worktree checkout. A checkout stays
  where it is: git has its path on record, and saved workspaces and Claude Code's history of the folder
  know it by that path. New worktrees go to `~/.whiskr/worktrees`.
- **A running old host** is found on its old socket. It is never used or ended. Its terminals are counted
  with the other-version terminals the app tells you about.

Nothing is ever deleted except the old copies of entries already moved. Isolated test runs never migrate.

## Rendering the meadow

`MeadowScene` is its own small Metal renderer. It is not RealityKit or SceneKit: a measured spike showed
Metal used the same GPU time as RealityKit but a third of the CPU and a quarter of the memory, and it can
stop drawing when nothing moves.

- Shaders are compiled from source at launch (about 100 ms), so building needs no Metal toolchain.
- One clay shader family draws every sculpted thing. Per-instance flags choose how each is lit. Materials
  are baked into vertex colour and roughness, so a prop is one draw.
- Plants are animated in a compute pass, once per plant per frame. Grass is drawn before the ground, so
  hidden ground pixels are rejected early.
- Frames come from a `CAMetalDisplayLink`, at the rate the display presents. The render scale adapts to
  hold the frame budget. The scene's per-frame update allocates nothing, and a test checks this.
- After 5 seconds with nothing new the meadow rests at 12 Hz, its own time slowed to 0.4 so each frame
  moves things as far as a frame at 30 Hz would (fireflies, lamps and lanterns included: they run on that
  time). Input brings the full rate back at once. A change in the world (`world`, `settings`, the
  selection, a note) ends the rest but is not input: it draws at 30 Hz unless something in the scene moves
  fast (`Stage.restful`), and rests again 5 s later. Hidden or covered, it draws nothing. The rule is
  tested frame by frame on a clock of the test's own (`RestTests`), by day and by night. While keys are
  typed into a terminal it draws at most 30 times a second, at the same pace, and full rate returns 1.5 s
  after the last key (`yieldFrames`).
  With Animate Meadow off (`MeadowView.animatesAmbient`), the display link pauses 3 s after the scene
  stands still and wakes for the next change.
- The ground is the fine 800-unit grid round the middle plus a coarse ring out to 1,600 units (laid a
  little under it where they overlap), and the far plane moves back with the view, so the view never sees
  past the land into the fog; far hills sink as the eye nears them (`Meadow.hill`), and the column's grass
  strip is drawn in the foreground between a far-back eye and the blankets. `GroundTests` renders every
  arrangement and size at the lowest, usual and highest tilt, zoomed in and all the way out, with the sky
  painting any hole in magenta (`Renderer.marksVoid`), and checks no hill stands round the eye.
- The sky is worked out on the Mac (`Meadow/Sky.swift`): the sun's height by NOAA's solar calculator, the
  day's sunrise and sunset from it (tested against almanac times for several cities, the polar day and
  night, and a clock change), the moon's phase, altitude and the direction of its lit edge by the
  Astronomical Almanac's low-precision series. Without a place (the scene's default, and every test that
  does not give one) the moon is a steady full one, so nothing drawn depends on today's date. The moon is
  drawn where a low-tilted view shows sky (`MeadowDrawer.moonCenter`: the top left of the picture), before
  the stars and marking depth, so its dark side hides them. With Follow the Clock, `Daylight` picks the mood (night, twilight, dawn or dusk, day) by the sun's height
  rather than by the hour, easing from the morning's pink to the evening's gold across solar noon and
  midnight. Where: the place real weather last found (`WorldSettings.place`), else a guess from the time
  zone (`MeadowPlace.estimate`: the zone's city from a small table, else its standard offset's
  longitude). Nothing asks for the location for this, and nothing is sent.
- Real weather is one Open-Meteo request every 15 minutes (`MeadowWeather.openMeteoURL`): temperature, WMO
  code, cloud cover, wind speed, direction and gusts, precipitation, rain, showers, snowfall and
  visibility. The wind's direction is eased round over a couple of seconds and its gusts travel as an
  offset moved on each frame (`Stage.gustDrift`), so a new direction never makes the grass jump. Each
  effect is a `MeadowSettings.Effects` member, one per switch in Settings › Meadow. Lightning
  (`Lightning`) is a pure function of the meadow's own time, so it costs no frames of its own, stops with
  that time when the animation is off, and is gated off under Reduce Motion. None of this keeps the meadow
  from resting. `--perf-flows sky` checks it in the app; `--sky-moment`, `--weather-fixture` and
  `--weather-place` stop the clock, give the weather, or fetch it for a given place, without the
  location question.
- Terminals draw with SwiftTerm's Metal renderer (`TerminalSurface.drawsWithMetal`), each on a render
  thread of its own; the main thread only says a frame is due. SwiftTerm's default, Core Graphics, drew
  every frame on the main thread beside the meadow's frames and typing.
- SwiftTerm's shaders are compiled once at launch, off the main thread (`TerminalShaderWarmup`, from
  SwiftTerm's `Shaders.metal`, copied in by a build step), so the first terminal after an install or update
  does not wait 75–180 ms for Metal's compiler. A terminal out of the window for 30 s gives its Metal
  renderer back (drawables, atlases, buffers: about 27 MB per tab at full width on a Retina display), and
  takes a new one, drawn at once, when shown (3–15 ms).
- The scene is optimised even in Debug builds (`Scene/Package.swift`), as is SwiftTerm
  (`native/App/Packages.xcconfig`): the scene's update and encoding run on the main thread beside typing,
  and SwiftTerm parses on each pane's connection thread and re-wraps on resize on the main thread.
- `make run` builds Release. Debug (`make debug`) is for development; `make profile` is Release's
  optimisation with the Debug test harness, for `make perf`.

## Measuring

`make perf` runs the profile build invisibly (`--isolated … --background --perf`, `DebugPerf.swift`) and
prints what a person at the window would get. The run's window is never on screen, so four things stand in
for being in front: the meadow draws as if on screen and key; terminals tick on Core Video's display link
(`SWIFTTERM_FORCE_CVDISPLAYLINK`), which keeps the display's rate for a covered window, instead of the
view's own link, which stops; the window counts as the key window of the active app; and the run holds off
App Nap, as a window in front is never napped. Every key and
click goes through `NSApplication.sendEvent`, to whatever the window's views say is under the pointer
or has the keyboard. A frame counts as drawn when SwiftTerm reports it drawn (`TerminalView.onFramePresented`)
or, for the window's own views, once Core Animation has committed it; the compositor's last step to the
glass (about one refresh) is not seen. Main-thread stalls are a ping every 4 ms from a thread of its own
(the editor's runs ping every 2 ms), never a main-thread timer's lateness: macOS fires an unseen app's
timers late on purpose, and stacks taken at such moments showed the main thread asleep. Memory is the
app's footprint with one tab and with 24, and again once the hidden tabs have given back their renderers.

Four stand-ins keep the runs honest about what a person at the window gets. Menus are recorded, never shown
(`MenuStandIn`: a real pop-up would block the run in its tracking loop and appear on screen), with each
item as AppKit validates it and what its action reaches. Sounds and notifications are recorded as what
would be played (which sound, how loud) and posted (title, body, actions), never played or posted. The
meadow's own clock, a `CAMetalDisplayLink`, gives a window that is not on the active Space no frames
after the first few, so in measuring runs (`assumesOnScreen`) the meadow is driven instead by the
screen's display link, taking a drawable from its layer and drawing and presenting each frame through
the same path and pacing; every idle stretch checks that the meadow drew, and fails "not measurable"
when it did not. And the window is looked
at mid-drag and mid-transition from the layer tree (`CALayer.render(in:)`, honouring `zPosition`), which,
unlike `--snapshot`'s `cacheDisplay`, includes layers added beside a view's drawing, such as a divider's
highlight. A divider's tracking loop does not drain the main queue, so a drag's pacing is each step's time
to its commit and the run loop's longest turn, not the pings.

The interface's own transitions are measured frame by frame (`motion`, `DebugAnimations.swift`, last of the
measured flows): each is set off by its key or click, and the part of the window it moves is read at every
refresh of the display (`NSScreen`'s display link) from Core Animation's presentation layers. Reported:
frames, dropped refreshes, the longest frame, the first change after the action and the main thread's
longest hold; a jump (one frame) fails where the design moves something.

Before the measurements come the checks, each an invisible run of its own (`--perf-flows`): closing, sizes
and interactions; the first five minutes (`journey`: Home, a folder, a terminal, a Claude through every
state, tabs, splits, workspaces; three runs on one folder, across ⌘Q and ⌥⌘Q); files, the editor, diffs
and Changes (`files`); the window's regions, sizes, themes and Settings (`layout`); and abuse (`robust`:
floods, binary and wide text, pastes, resize storms, the session host going away); every control of the
bars clicked at its middle and edges, failing a press that lands on anything but the control or on a view
that lets the window move, and again straight after the bars change (`chrome`; the bars' hosting views,
`BarHostingView`, send a press that lands on SwiftUI's own views to the bar control under it); a Claude stand-in started through a shell function of the user's kind
with `--settings`, every event's real hook commands, and what would be heard and shown in each place a
person can be (`alerts`); every way of choosing on the right, with the meadow moved away first, and agent
events that must not move it (`meadow`); and every divider dragged, the window resized and each region
shown and hidden, looked at mid-drag (`resize`); a tab split into panes, as the owner used it, with real
clicks on its segments, their close buttons, middle clicks, ⌘W, Close Tab and ⌘Z, "+" after the last tab,
the panes' headers, and the line between panes and the focused header read from the drawn window in
every built-in theme (`split`); tabs picked up and dropped by real press, drag and release events into the
row, onto each side and the middle of a pane, onto another blanket, onto nothing and onto their own pane,
and given up with Esc, each preview checked against what the drop did and the held tab's springs read
every frame, with nothing left behind (`drag`); and New Workspace and Open Folder… from every place they
are offered, on Home with and without workspaces (`home`).

**Dragging a tab** is the app's own, not an AppKit drag session (whose picture the system moves, with no
springs and no say in what it shows). `TabMouseView` starts it past 4 pt of movement; `TabDragging` then
follows the mouse with a local event monitor (the tab's view may be rebuilt under the pointer), works out
each frame what a drop would do (`PaneArea.dropTarget`, steadied by `PaneTree.dropSide(…after:)`;
`NavigatorController.blanket(at:)`; a place in the row from the tabs' AppKit views), and tells the row
through `TabDragState` (the row parts where the tab would land). The pictures are Core Animation layers
in `TabDragOverlay`, above the whole window and taking no click, stepped by springs on the view's display
link; nothing is laid out per frame.

Nothing in `make perf` depends on when it runs: the runs show the meadow by day (`--time day`), and the
idle flow sets the time of day itself, measuring by day and by night. Idle is measured once nothing is due
to change (the demo's cats doze off `AgentWorld.napAfter` after they are made; that is waited out) and the
meadow has come to rest, for 5 s each: by day and by night with the window key, then by night with it not
key, and hidden (taken off the screen). Each stretch reports the app's and the session host's CPU and
wakeups (`proc_pid_rusage`), the meadow's frames and GPU milliseconds per second, terminal frames and
chrome updates; day and night are held to the same limits, and to the meadow resting within 12 s.

Timings are only comparable on a quiet Mac. `Scripts/perf.sh` waits, up to ten minutes before each run,
until other programs keep at most one core busy (`top`), and prints how busy the Mac was. Each run also
samples, twice a second, every core's time less its own (the app, its session host and every process
under either: `MachineLoad`), and a limit passed while others kept more than a core busy is "not
comparable": neither a pass nor a failure. `make perf` then exits with 3 rather than 1, and says to run it
again when the Mac is quiet; a failed check still fails.

The editor has runs of its own in `make perf` (`DebugFiles --measure-files`, files `Scripts/perf.sh` writes:
50,000 lines of the app's Swift, 50,000 lines of TypeScript, a 2 MB one-line JavaScript file and lines of
22,800 characters): opening, scrolling a screenful, jumping to the end and back, typing in the middle, the
time until every line is coloured and the main thread's longest hold meanwhile, and opening a block comment
(which recolours the rest of the file).
