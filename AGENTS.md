# AGENTS.md

Instructions for AI coding agents working in this repository. Human contributors: the same rules apply,
and [CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## What this is

Whiskr is a native macOS terminal multiplexer for Claude Code. Workspaces, tabs and panes of real
terminals sit on the right. On the left, a 3D clay meadow shows one picnic blanket per workspace, with a
black cat for each Claude, acting out its state. Swift 6.2, AppKit and SwiftUI, Metal for the meadow,
SwiftTerm for terminals. No web view, no Node.

## Layout

| Path | Contents |
|---|---|
| `native/App/project.yml` | The Xcode project's source. `Whiskr.xcodeproj` is generated from it (`make project`); never edit the project by hand |
| `native/App/Makefile` | Every build, test and packaging command |
| `native/App/Whiskr/` | The app target: `App/` (launch, menus, debug runs), `UI/`, `Model/` (the `Workbench`), `Terminal/`, `Files/`, `Editor/`, `Agents/` (hook listener, notifications) |
| `native/App/WhiskrKit/Sources/WhiskrKit` | Logic without AppKit: agent states from hooks, layout, themes, TextMate syntax colouring and the bundled languages, the key table, diffs, git, the host protocol, the migration from the old name |
| `native/App/WhiskrKit/Sources/COniguruma` | Oniguruma, vendored unchanged: the regular expressions TextMate grammars use |
| `native/App/WhiskrKit/Sources/TerminalHost` | The session host (owns every pseudo-terminal) and the client the app uses |
| `native/App/WhiskrKit/Sources/Paw`, `PawTool` | The `paw` command-line tool |
| `native/App/WhiskrKit/Sources/WhiskrMeadow` | Maps the app's model to the scene's world |
| `native/App/WhiskrHost/` | The session host's `main` |
| `native/Scene/` | `MeadowScene`: the meadow, cats and camera, with its own Metal renderer; `MeadowDemo` is a standalone viewer |
| `docs/` | `ARCHITECTURE.md`, `DESIGN.md` (interaction and look rules), `RELEASING.md`, `logo.svg` |

## Commands

Run from `native/App`:

```sh
make test         # Kit and scene tests (Swift Testing); must pass with zero warnings
make test-kit     # WhiskrKit only (about 30 s)
make test-scene   # MeadowScene only
make build        # Release app (what `make run` opens)
make debug        # Debug app, with the test harness
make profile      # Release's optimisation with the test harness (for `--perf` runs)
make perf         # invisible performance and tab checks of the profile build; fails on a regression
make release      # Release app
make dist         # unsigned zip and checksum
make project      # after changing project.yml
```

Point builds at your own folders when you work beside someone's running copy, for example
`make build DERIVED=~/Library/Developer/Xcode/DerivedData/Whiskr-agent SCRATCH=~/Library/Developer/Whiskr-agent`.

## Rules

1. **Build outside the source tree.** Use the Makefile, or pass `-derivedDataPath` under
   `~/Library/Developer`. Never put build products, `.build`, DerivedData or snapshots in the repository.
2. **Never show a window, play a sound or post a notification when checking your work.** Run the app only
   as a Debug or profile build (`make debug`, `make profile`) with `--isolated <scratch folder>
   --background`. Isolated runs have their own settings, support folder and session host, and never read
   or change the user's. Use `--snapshot <png>` to see the window, `--script` (see
   `Whiskr/App/DebugScript.swift`) to drive menus and keys, and `--perf` (`Whiskr/App/DebugPerf.swift`,
   `make perf`) to measure what a visible window would show. An isolated run exits with status 70 when it
   crashes: that is a bug to fix, not noise. A Debug build refuses every one of these options without
   `--isolated <folder>`, and an isolated run starts no real Claude Code, plays none of the app's sounds
   or beeps, and keeps its shells' history to itself.
3. **Never disturb the user's own Whiskr.** Their sessions may be running inside it. Do not build into
   the DerivedData folder their copy runs from. Do not quit, relaunch or signal it, its session host
   (`whiskr-host`) or any process you did not start. Stop what you started by its own PID, never by port
   or name pattern. Do not touch `~/Library/Application Support/Whiskr`, `~/.whiskr`, the app's user
   defaults or `~/.claude*`.
4. **No signing.** The app is unsigned on purpose (the linker's ad-hoc signature only). Do not add signing
   identities, certificates, keychain access or notarisation.
5. **Zero warnings** from our code, in the app build and both test suites.
6. **Tests for logic.** Put logic in `WhiskrKit` (or `MeadowScene` for the scene) and test it there. Tests
   use temporary folders of their own and clean up.
7. **Localise everything a user reads,** in English and Japanese, using the words in
   [docs/DESIGN.md](docs/DESIGN.md#words).
8. **Respect the design rules** in [docs/DESIGN.md](docs/DESIGN.md). In particular, no agent event may move
   the window, focus, tab, scroll or camera. The cats keep their look: black, no mouth, fixed short paws.
9. **Keep changes small and in scope.** No new dependencies, and no features beyond the task.
10. **Record what users notice** under **Unreleased** in `CHANGELOG.md`. Record a design decision in
    `docs/DESIGN.md` or `docs/ARCHITECTURE.md` in the same change.

## Where decisions live

- `docs/DESIGN.md`: what the app is and is not, the vocabulary, the states and how they look, attention
  rules, the meadow and cat look rules.
- `docs/ARCHITECTURE.md`: processes, modules, the session host and its protocol, hooks, files on disk,
  the migration from the app's earlier name.
- `docs/RELEASING.md`: how releases are drafted, and what an unsigned build means for users.
