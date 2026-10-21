# One-click cloud sign-in (to-do B2): implementation brief

This brief drives the implementation of to-do item **B2** ("Signing in to
ChatGPT or Claude means installing a command-line tool first") in `to-do.md`.
Read that item in full first; this brief records the facts checked while
planning and the decisions taken, so the worker doesn't need to re-derive them.

## Goal

Signing in to ChatGPT or Claude from Settings → Cloud and search (and welcome
setup's Connections step, which shares `CloudConnectionControls.swift`) is one
click on a Mac with nothing installed:

- **ChatGPT:** Enigma downloads its own pinned copy of OpenAI's Codex package
  on first **Sign in**, then continues straight into the existing browser
  sign-in.
- **Claude:** Enigma offers **Install Claude Code**, which runs Anthropic's
  official installer in Terminal and goes on to sign-in. Claude Code is never
  bundled or redistributed.
- Detection finds Node-manager and other non-default installs, runs each tool
  with its own folder on `PATH`, and says where it looked when nothing is found.

## Facts checked while planning (2026-10-21)

- OpenAI's GitHub release `rust-v0.163.0` (latest stable) publishes a full
  macOS package per architecture:

  | Arch | URL | Bytes | SHA-256 |
  | --- | --- | --- | --- |
  | arm64 | `https://github.com/openai/codex/releases/download/rust-v0.163.0/codex-package-aarch64-apple-darwin.tar.gz` | 133412281 | `b0344fc2e41f15e0071147e5869008047b8ff4bf2c4a8897975d3bae3f103b34` |
  | x86_64 | `https://github.com/openai/codex/releases/download/rust-v0.163.0/codex-package-x86_64-apple-darwin.tar.gz` | 144982749 | `0c182d6194da7003943678dc87866b54b3dee719edaf8d092f304affbc6b57d1` |

  The arm64 checksum was recomputed locally and matches GitHub's digest.
- Layout of the archive (paths are relative, no top-level folder):
  `bin/codex` (≈250 MB), `bin/codex-code-mode-host` (≈65 MB),
  `codex-package.json`, `codex-path/rg`, `codex-resources/voice/…` (bin, lib
  dylibs, licenses, plugins, manifests). `codex-package.json` is:
  `{"layoutVersion":1,"version":"0.163.0","target":"aarch64-apple-darwin","variant":"codex","entrypoint":"bin/codex","resourcesDir":"codex-resources","pathDir":"codex-path"}`.
- `bin/codex --version` prints `codex-cli 0.163.0`, and it supports
  `codex app-server generate-json-schema`, which `CodexAppServer.prepareFileMode`
  needs. The smaller `codex-app-server-package-*` asset ships a standalone
  `codex-app-server` binary **without** `generate-json-schema`, so it is not
  usable without changing File Mode; don't use it.
- The binaries are Developer ID-signed by OpenAI (team `2DC432GLL2`),
  notarized, hardened runtime. `bin/codex`'s designated requirement is
  `identifier codex and anchor apple generic … certificate leaf[subject.OU] = "2DC432GLL2"`,
  so a Keychain login made by another OpenAI-signed `codex` should stay
  readable. Don't re-sign, strip or modify anything in the package.
- ChatGPT.app ships Codex at
  `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (a shell
  wrapper around a bundled `CodexCLI.app`), not at `Contents/Resources/codex`.
- Homebrew's `codex` (`/opt/homebrew/bin/codex`) is a symlink to
  `../lib/node_modules/@openai/codex/bin/codex.js`, a `#!/usr/bin/env node`
  script.
- The repository's `main` branch has no branch protection.

## Decisions

### ChatGPT: a built-in Codex runtime

1. **Pin** Codex 0.163.0 as above in a new type modelled on
   `LocalVisionRuntime` (`Enigma/LocalInference/LlamaServerVisionEngine.swift`):
   a `VerifiedModelArtifact` per architecture chosen with `#if arch(arm64)`,
   downloaded with `VerifiedModelArtifact.download` (resume, size and SHA-256
   checks) under a `DownloadActivity`. New Codex versions ship with Enigma
   releases by bumping the pin; put a short comment at the pin saying how
   (the `gh release view … --json assets` digest, and re-check the layout).
2. **Install** into a versioned folder under Application Support, separate
   from the Codex home (`AI Spotlight/Codex`, which holds Enigma's Codex
   config and must stay as is), for example
   `AI Spotlight/Codex Runtime/codex-0.163.0/`. Stage next to it on the same
   volume and move into place atomically; if another instance already put the
   version there, keep that copy. An install first removes `.staging-*`
   folders older than a day (a newer one may be another instance's). Older
   `codex-*` folders are **not** removed after an install (a running app server
   or code-mode host may use them); see "Pin bumps" below.
3. **Extract safely**, following `LocalVisionRuntime.install`: list with
   `tar -tzf` first; reject absolute paths, `..` components, and any top-level
   entry other than `bin`, `codex-package.json`, `codex-path`,
   `codex-resources`; extract with `--no-same-owner`; reject any entry that
   resolves outside the staging folder. Then check `codex-package.json`
   (version, target matching this architecture, entrypoint `bin/codex`),
   that `bin/codex` and `bin/codex-code-mode-host` are executable files, and
   run a smoke test (`bin/codex --version` contains `0.163.0`) with a timeout
   and a minimal environment.
4. **Lookup order** in `CodexRuntimeConfiguration.executableURL()`:
   `AI_SPOTLIGHT_CODEX_PATH` (developer override) → the installed pinned
   runtime → the newest other built-in `codex-<version>` (numeric order; other
   names ignored) → the existing system locations (Homebrew, `/usr/local/bin`,
   `~/.local/bin`) and the hardened candidates below → `PATH`. **Drop** the
   `Codex.app` and `ChatGPT.app` candidates. People with a working system
   Codex keep using it without a download.
5. **Sign in is always enabled.** When no Codex is found, **Sign in** first
   downloads the pinned runtime with progress, **Cancel**, and a clear failure
   message (the row can then retry with **Sign in**), and on success continues
   into the existing `signInWithChatGPT` browser flow without a second click.
   Say before the click that the first sign-in downloads Codex from OpenAI and
   its size (for example "Signing in the first time downloads Codex from
   OpenAI · 127 MB"; compute the label from the pin, not a literal). Drive the
   download from `CloudSettingsModel` through an injectable install closure
   (as `LocalFileToolsInstallation` does) so tests never touch the network.
6. **Environment:** keep the isolation exactly (`CODEX_HOME`, the disabled
   features, `forced_login_method`, `cli_auth_credentials_store="keyring"`).
   Prepend the executable's own folder to the fixed `PATH`, and for the pinned
   runtime also its `codex-path` folder.
7. **Messages:** "Codex not found" is not reachable from the ChatGPT row. With
   no Codex, Check sign-in status gives the neutral
   `SignInCheck.notSignedInNeedsCodexDownload`: "Not signed in · Sign in
   downloads Codex from OpenAI (<size from the pin>)". A failed attempt says
   whether the download, install or start failed. The row shows
   **installing Codex** after the download reaches 100%. Sign in awaits the
   login-shell answer before deciding to download. Update
   `CodexError.notInstalled`'s text, and remove the "Codex installation instructions" link and
   the "The Codex CLI is required" note.
8. **Pin bumps.** All Enigma builds share `Codex Runtime`. At launch (not in
   test hosts), in the background: remove day-old `.staging-*`; if the pinned
   version is installed, remove only `codex-<version>` folders older than the
   pin (newer and unparseable names stay); if only another built-in version
   exists and none is newer than the pin, install the pinned one quietly under a background activity (no UI,
   no browser sign-in). After a failed upgrade, the same version waits 24 hours
   (`shouldRetryUpgrade`, recorded in `UserDefaults`; a failure time in the
   future doesn't block a retry). The decision is the pure
   `CodexRuntime.launchStep`. Failures after the download report as install
   failures, not download failures.
9. Add Codex's Apache-2.0 notice to `Enigma/Resources/ThirdPartyNotices.txt`
   (note that it is downloaded from OpenAI on first sign-in, not bundled).

### Claude: one-click install, never bundled

1. When Claude Code isn't found, the row's main action is **Install Claude
   Code**. It writes a `.command` script (like `ClaudeCodeRuntime.signInScript`)
   that runs Anthropic's official installer and then, if it succeeded, runs the
   freshly installed `claude auth login --claudeai` in the same Terminal
   window, so one click covers install and sign-in. Use `#!/bin/bash` with
   `set -o pipefail` (or equivalent) so a failed `curl` stops the script.
   Enigma then waits as the existing sign-in does (re-detect, then poll
   `claude auth status`), with **Cancel**, and on success selects Claude and
   loads its models. Allow longer than the sign-in's five minutes, since the
   install adds time.
2. Also show the command with a **Copy** button (it reverts to "Copy" after
   2 s) and the three short steps from the to-do item (open Terminal, paste the
   command, come back and press **Check again** then **Sign in**), inside an
   `EnigmaDisclosure` titled **Terminal steps**, hidden while Enigma waits. The existing "Check sign-in status"
   button may be relabelled **Check again** while Claude Code is missing.
3. **Verify the install command** against Anthropic's current setup docs
   (https://code.claude.com/docs/en/setup) before hard-coding it; the to-do
   expects `curl -fsSL https://claude.ai/install.sh | bash`. Keep the command
   in one constant.
4. Add a short note pointing to the Anthropic API-key route (the API keys
   section of the same Settings page) as the officially supported way to use
   Claude in a third-party app. It is shown in Settings, outside the
   disclosure; welcome setup leaves it out for room (`showsAPIKeyNote`).
5. Mention the install command once in `docs/Claude-Code-Setup.md`.

### Hardened detection

1. Shared by both tools (one helper, not two copies): besides today's
   candidates, check `~/.nvm/versions/node/*/bin` (newest version first),
   `~/.volta/bin`, fnm's node-version `installation/bin` folders
   (`~/.local/share/fnm/…` and `~/Library/Application Support/fnm/…`),
   `~/.asdf/shims`, `~/.npm-global/bin` and `~/.bun/bin`. Add a
   `~/Applications` location only if there is a real, known layout for that
   tool; otherwise leave it out and say so in the debrief.
2. Ask the shell: `$SHELL -ilc 'command -v <tool>'` (interactive, so zsh
   reads `~/.zshrc`, where nvm, fnm, asdf and Bun add themselves) with a
   5-second timeout, off the main actor, at launch, at sign-in, on the explicit
   check, and on a background refresh only while the tool isn't found. Accept only
   an executable whose name is the tool's. Cache only a definite answer (exit
   0, or 1/127 for "not found"); a timeout or failure is asked again, and the
   explicit check buttons forget a cached "not found". A timeout kills the
   shell's process group. `LoginShellToolLookup.shared` does nothing in test
   hosts, and the default Codex install throws there. Accept only an absolute path to an executable file. Never block the
   main thread: today `executableURL()` is synchronous and is called from
   `CloudSettingsModel`'s init and refreshes, so the shell lookup must run
   asynchronously (for example at refresh time) and feed a cache that the
   synchronous lookup reads.
3. Run each tool with its own folder (as found, not symlink-resolved) first on
   `PATH`, so a Node-based install finds its `node`.
4. Last resort for Claude: a **Choose Claude Code…** button (an `NSOpenPanel`
   for a file, with `resolvesAliases = false` so the path is kept as picked)
   that saves the chosen path in `UserDefaults`; the lookup uses it
   only while it is still an executable file.
5. When nothing is found, the "not found" result says where Enigma looked
   ("looked in ~/.local/bin, /opt/homebrew/bin, …"), abbreviating the home
   folder to `~`. Keep it readable: list folders, not every nvm version.

## Constraints

- Follow `AGENTS.md`: Swift 6, existing style, `docs/design/UI-Style.md` for
  the controls (existing `EnigmaRow`, `EnigmaConnectionNote`,
  `EnigmaStatusLine`, `EnigmaProgressBar`, `enigmaButtonStyle`). New source
  files must be added to `Enigma.xcodeproj/project.pbxproj` (it lists files
  explicitly). Accessibility labels on every new control.
- Privacy: no new data is saved beyond the optional chosen Claude Code path;
  the Codex download sends nothing but the HTTPS request to GitHub.
- Tests must be offline and deterministic (`docs/Testing.md`): no network, no
  real Codex or Claude Code, no real login shell in unit tests (inject it).
  Cover at least: lookup order (override, pinned runtime, system, hardened
  folders, chosen path, PATH) using temporary folders and an injected home and
  environment; the ChatGPT.app and Codex.app candidates being gone; extraction
  of a locally built fixture `.tar.gz` (success, path traversal, unexpected
  top-level entry, escaping symlink, wrong `codex-package.json`, failed smoke
  test, old version cleanup); Sign in when Codex is missing → install → sign-in
  continues; cancel and failure during the download; the Claude install script
  contents and the install-then-sign-in wait; the "looked in …" message; the
  login-shell lookup's timeout and parsing with an injected runner; `PATH`
  containing the tool's own folder.
- Update `docs/ChatGPT-Setup.md` (setup steps, lookup order, the download,
  privacy, how it works table, limitations, tests) and
  `docs/Claude-Code-Setup.md` likewise; touch `docs/File-Mode.md` or
  `docs/Welcome-and-Settings.md` only where they describe the changed
  behaviour. Do not tick B2 off in `to-do.md` (that happens once it is on
  `main`).
- Owner-only items, reported rather than coded: confirming OpenAI's current
  terms for embedding `codex app-server` in a third-party app, confirming that
  Enigma's Claude subscription route fits Anthropic's terms, and any written
  approval to bundle Claude Code.

## Verification

`scripts/verify-xcode.sh test` (whole suite), plus `build` and `analyze`,
must pass with no new warnings in changed files.
