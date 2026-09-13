# Security

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue:

1. Open the repository on GitHub and go to **Security › Report a vulnerability** (GitHub's private
   vulnerability reporting).
2. Describe the problem, the steps to reproduce it, the Whiskr version or commit, and your macOS version.

The maintainer will reply as soon as possible. Fixes are made in a private security advisory and published with
credit to you, unless you would rather not be named. If the reporting form is not available, open an
issue that only asks a maintainer to contact you, without any details of the problem.

Only the latest code on `main` (and, once releases exist, the latest release) receives security fixes.

## Trust model

Whiskr is a terminal. Its whole job is to run your shell and the programs you start, with your own user
account, files and environment. It is **not a sandbox** and does not try to contain what runs in it.

### The session host

- The terminals belong to `whiskr-host`, a process inside the app that runs as you and starts your
  programs exactly as a terminal does. Whatever you or Claude run there has your full permissions.
- The host listens on a Unix socket in `~/Library/Application Support/Whiskr/host/`. That folder is
  created with mode 0700 and the socket with mode 0600. If the path is too long for a socket address, it
  goes in a 0700 folder in your private temporary folder instead. On every connection the host checks that
  the peer runs as the same user (`getpeereid`) and refuses anyone else.
- Any process running as you can connect to that socket, as it could to your files. That includes any
  program in any Whiskr terminal. Such a process can start terminals, type into them and read their
  screens; this is what `paw` does. Treat the socket like your shell: anything that already runs as you
  can use it.
- The host keeps the last 4 MiB of each terminal's output in memory, to redraw a pane when the app
  reattaches. It writes no output to disk. Its log, `host.log`, holds diagnostics only.

### Claude Code hooks

- Inside Whiskr's terminals, `claude` runs through a small shim that adds this pane's hooks with
  `--settings`. Your own `~/.claude*` settings, `CLAUDE.md` and shell files are never changed.
- The hooks post events to a listener in the app that accepts connections on 127.0.0.1 only, on a port
  chosen at each launch, with a new random secret in the URL. The address is written to files readable
  only by you (mode 0600, in a 0700 folder), and each request is checked against the secret.
- The listener only watches. It answers every hook with "no opinion" and never approves or denies
  anything for Claude. Allow and Deny (from the answer card or a notification) are keystrokes typed into
  that terminal. They are sent only if the same request is still open and the terminal's screen has not
  changed.

### The app

- The app runs with the hardened runtime and without the App Sandbox. A sandboxed app's child processes
  inherit its sandbox, which would stop your shell from working. Terminal, iTerm2 and Ghostty ship the
  same way.
- **Builds are not signed or notarised.** Each executable carries only the ad-hoc signature the linker
  adds. macOS cannot tell you who built such an app, so build it yourself from source you have read, or
  check a download's SHA-256 checksum against the one published with the release. See
  [docs/RELEASING.md](docs/RELEASING.md).
- The only network request the app makes itself is to Open-Meteo, for "Real weather" (off by default),
  with your location rounded to about a kilometre.
