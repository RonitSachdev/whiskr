# Contributing to Whiskr

Thank you for helping. Whiskr is a small project with one maintainer, so a clear report or a focused pull
request goes a long way.

## Before you start

- **Bugs.** Search the open and closed issues first. Then open a bug report with the shortest steps that
  show the problem, what you expected, and your macOS, Xcode and Claude Code versions.
- **Ideas and larger changes.** Open a feature request and describe the problem before writing code.
  Whiskr deliberately leaves a lot out, so ask before building something big. The look and the
  interaction rules in [docs/DESIGN.md](docs/DESIGN.md) are decided, not open questions.
- **Security problems.** Do not open an issue. See [SECURITY.md](SECURITY.md).

## Building and testing

You need macOS 26 and Xcode 26.1 or later (Swift 6.2). Everything runs from `native/App`:

```sh
cd native/App
make build      # Debug build into ~/Library/Developer/Xcode/DerivedData/Whiskr-make
make run        # build and open the app
make test       # all logic tests: make test-kit (WhiskrKit) and make test-scene (MeadowScene)
make release    # Release configuration
make dist       # unsigned zip and checksum, as a release carries them
make project    # regenerate Whiskr.xcodeproj after changing project.yml (needs xcodegen)
```

- **Build outside the source tree.** The Makefile already does. If you build by hand, pass
  `-derivedDataPath` (or `DERIVED=` / `SCRATCH=` to make) pointing under `~/Library/Developer`.
- **Do not edit `Whiskr.xcodeproj` by hand.** Change `native/App/project.yml` and run `make project`. Commit
  both.
- **Checks that need the app** run it invisibly against a scratch folder, never against your own
  settings or sessions. Debug builds only:

  ```sh
  Whiskr.app/Contents/MacOS/Whiskr --isolated /tmp/whiskr-check --background --demo /tmp/whiskr-demo \
      --snapshot /tmp/whiskr-check/shot.png --after 8
  ```

  `--isolated` gives the run its own settings, support folder and session host. `--background` keeps the
  window invisible and click-through. `--snapshot` draws the window to a PNG and quits. An isolated run
  that crashes exits with status 70 instead of showing a crash report. Treat that as a bug. The full list
  of options is at the top of `native/App/Whiskr/App/DebugScenario.swift`.

## Code style

- **Swift 6 with complete concurrency checking.** The app target defaults to the main actor. The Kit and
  the scene state their isolation explicitly. A build or test run must produce **no warnings** from our
  code.
- **Keep the layers apart.** `WhiskrKit` has no AppKit, SwiftUI or Metal and is where logic goes, with
  tests. `TerminalHost` and `Paw` depend only on the Kit. `MeadowScene` knows nothing about terminals.
  `WhiskrMeadow` is the one bridge between the app's model and the scene.
- **Follow the surrounding code:** four-space indentation, no tabs, lines up to about 140 characters.
- **Comments say why,** in plain sentences. A type or function gets a doc comment saying what it is for
  and anything surprising about it. Do not leave notes about what you changed.
- **Every user-visible string is localised** (`String(localized:)` with a comment for translators) and has
  Japanese as well as English in the string catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`,
  and the Kit's own catalog). Use the vocabulary in [docs/DESIGN.md](docs/DESIGN.md#words): one word for
  each thing.
- **Tests use Swift Testing** (`import Testing`, `@Test`, `#expect`). Tests that touch the file system use
  their own temporary folders and remove them. Tests that start processes stop them.
- **No new dependencies** without discussing it in an issue first.

## Commits

- Write in the imperative, with a short summary line (about 72 characters) and a type prefix:
  `fix: keep the selection when a file reloads`, `feat: …`, `docs: …`, `test: …`, `refactor: …`,
  `build: …`, `ci: …`, `chore: …` ([Conventional Commits](https://www.conventionalcommits.org/)).
- Explain why in the body when it is not obvious from the summary.
- One logical change per commit. Keep generated files (the Xcode project, string catalogs) in the same
  commit as the change that produced them.

## Pull requests

Before you open one, check that:

- [ ] `make test` passes with no warnings, and `make build` succeeds.
- [ ] New logic has tests in the Kit or the scene package.
- [ ] Any new user-visible text is in English and Japanese.
- [ ] Nothing a Claude does moves the window, the focus, a tab or the camera (see docs/DESIGN.md).
- [ ] `CHANGELOG.md` has a line under **Unreleased** for anything a user would notice.
- [ ] Screenshots are attached for visible changes. Take them with `--snapshot` from an isolated run, so
      no personal paths or names appear.

## Licence of contributions

Whiskr is licensed under the [Apache License 2.0](LICENSE). By submitting a contribution you agree that it
is licensed under the same terms, as section 5 of the licence states. You must have the right to submit it.

We do **not** require a Developer Certificate of Origin sign-off (`Signed-off-by:`) or a contributor
licence agreement. Section 5 already covers what a project of this size needs, and a sign-off adds a step
for every contributor. If that changes, it will be announced here before it applies.

Files carry **no per-file licence header**. The licence's appendix recommends a short header in each file,
but it is optional. Here the licence and copyright notice live once, in `LICENSE` and `NOTICE` at the root.
Do not add headers to new files. If you add third-party
code or assets, keep their notices and add an entry to `NOTICE` in the same pull request.

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
