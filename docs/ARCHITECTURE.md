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
| `WhiskrKit` | `native/App/WhiskrKit/Sources/WhiskrKit` | Foundation | Logic with no UI: agent states from hook events, the story of a helper, layout and its saved form, themes, syntax lexer, Markdown parser, diffs, git status and worktrees, the host protocol, fuzzy ranking, `LegacyMigration` |
| `TerminalHost` | `…/Sources/TerminalHost` | WhiskrKit | The host server, pseudo-terminals, the client connection, the launcher |
| `Paw` / `PawTool` | `…/Sources/Paw`, `…/Sources/PawTool` | TerminalHost | The `paw` command-line tool and its `main` |
| `WhiskrMeadow` | `…/Sources/WhiskrMeadow` | WhiskrKit, MeadowScene | Maps the app's snapshot of workspaces and Claudes to the scene's world |
| `MeadowScene` | `native/Scene` | Metal, AppKit | The meadow, cats, props, camera and a small Metal renderer (`MeadowView`); `MeadowDemo` is a standalone viewer |
| `WhiskrHost` (tool target) | `native/App/WhiskrHost` | TerminalHost | The host's `main` |

`WhiskrKit` stays free of AppKit and Metal so its tests run in seconds with `swift test`.

## How Claude's state reaches the meadow

1. **Shell integration** (`ShellIntegration`). Each pane's environment puts a folder first on PATH. That
   folder holds a `claude` shim and a link to `paw`. zsh is pointed at a `ZDOTDIR` of ours that hands
   straight back to the user's own startup files and re-asserts PATH before every prompt. fish gets a
   `vendor_conf.d` script, and bash a `PROMPT_COMMAND`. None of the user's files are written.
2. **The shim** runs the real Claude Code with `--settings <hooks file>`. The hooks are command hooks
   that `curl` each event to the app's listener. They read the listener's address, at the moment they
   fire, from a per-pane file that each launch rewrites. With no app running they do nothing and never
   fail.
3. **The listener** (`HookServer`) accepts only 127.0.0.1, checks a per-launch secret, answers "no opinion"
   at once, and hands the event to `AgentMonitor`, which turns events into states (`AgentWorld` in the
   Kit).
4. **Before any hook**, the host watches each terminal's foreground process group ten times a second while
   a window is connected. A cat appears as soon as `claude` is the foreground program.
5. The `Workbench` builds a `SceneSnapshot`, `WhiskrMeadow` maps it to the scene's `World`, and
   `MeadowView` animates the difference.

Helpers' own conversations are read from Claude Code's transcript files, because hooks do not carry them.

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
- **One connection per pane**, each read on its own thread, plus one for the app. A viewer that cannot keep
  up stops the host reading that terminal (backpressure) instead of filling memory.
- **Reattaching.** The host keeps each terminal's latest 4 MiB of output. When older output is dropped, it
  first restores the terminal modes the program had set (alternate screen, bracketed paste, mouse and
  focus reports, keyboard protocol, cursor) and asks the program to redraw. Output printed at an earlier
  size is replayed at that size.
- **Sizes.** A resize reaches the program only after the size has held still for 80 ms. During a live
  drag, terminals keep their size and take the new one once at the end, so a long scrollback re-wraps
  once.

## Files on disk

| Where | What | Notes |
|---|---|---|
| `~/Library/Application Support/Whiskr/layout.json` | Workspaces, tabs, panes, their folders, the host terminal each pane shows | Written on changes and on quit. Which workspace was selected is not kept: a launch lands on Home |
| `…/Whiskr/agents.json` | The Claudes' last known state | So cats come back as they were after a relaunch |
| `…/Whiskr/Themes/*.whiskrtheme` | The user's own themes (plain JSON) | |
| `…/Whiskr/shell/` | The shim, zsh and fish integration | Rewritten at every launch |
| `…/Whiskr/hooks/` | The hooks settings and each pane's listener address | Mode 0700, files 0600; rewritten at every launch |
| `…/Whiskr/host/` | The host's socket, lock and log | Mode 0700, socket 0600 |
| `~/.whiskr/worktrees/<repo>/<branch>` | Git worktrees the app makes | Changeable in Settings › General |
| User defaults `app.whiskr.Whiskr` | Settings, recent folders, window layout | |

Debug builds run with `--isolated <folder>` keep all of this inside that folder, with their own defaults
suite and their own host.

## Identifiers

| What | Identifier |
|---|---|
| App bundle | `app.whiskr.Whiskr` |
| Session host | `app.whiskr.Whiskr.host` (executable `whiskr-host`) |
| `paw` | `app.whiskr.Whiskr.paw` |
| Theme file type | `app.whiskr.theme` (`.whiskrtheme`) |
| Dragged tab type | `app.whiskr.tab` |
| Pane environment | `WHISKR_PANE`, `WHISKR_BIN`, `WHISKR_HOOKS`, `WHISKR_ZDOTDIR`, `WHISKR_XDG_DATA_DIRS`, `PAW_ID`, `PAW_SOCKET`, `PAW_PARENT`, `PAW_NAME`, `PAW_WORKTREES`; `TERM_PROGRAM=Whiskr` |

## Launching

A launch brings every workspace back and selects none: the window opens on Home, once the layout is
restored (or after a second, if the session host is slow to start), so it never shows an empty Home that
fills in. Each saved pane is decided by `ResumePlan` (in the Kit, tested):

- the session host still holds its terminal: it is attached, screen and process as they were, and
  nothing is typed;
- otherwise a fresh shell starts in its folder, and nothing is typed, except for a pane that ran Claude:
  that one types `claude --resume <id>` (Settings › Resume Claude in restored panes);
- never while another version's host, or the earlier-named app's, still holds terminals: those Claudes may
  be alive there, and a resume would start a second Claude on the same conversation. The launch notice
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
- After 5 seconds with nothing new the meadow rests at 12 Hz, and any input or event brings full rate
  back. Hidden or covered, it draws nothing.
- The scene is optimised even in Debug builds (`Scene/Package.swift`), as is SwiftTerm
  (`native/App/Packages.xcconfig`): both run on the main thread beside typing.
