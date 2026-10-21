# ChatGPT via Codex

Enigma can chat through your ChatGPT plan by running OpenAI's Codex CLI on this
Mac. Usage counts against the plan's Codex allowance, not API billing, and the
sign-in belongs to Enigma alone. The OpenAI API-key route is a separately billed
alternative; neither route falls back to the other.

## Setup

1. Open **Settings → Cloud and search → Subscriptions → ChatGPT**, or the
   **Connect what you use** step of welcome setup. Nothing needs to be
   installed first. If Enigma finds no Codex on this Mac, the row says that
   signing in the first time downloads Codex from OpenAI, and its size.
   **Check sign-in status** shows **Checking…** while it runs and then always
   reports the result under the row: signed in as an account, not signed in
   (choose **Sign in**), not signed in with a note that **Sign in** downloads
   Codex from OpenAI and its size (when this Mac has no Codex yet; that isn't
   a problem), or the error with a hint to retry.
2. Choose **Sign in**. When no Codex is found, Enigma first downloads its own
   copy (see [Built-in Codex](#built-in-codex)): the row reads
   **downloading Codex** with a progress bar and **Cancel**, then
   **installing Codex** while the package is checked. If that fails, the row
   says whether the download, the install or starting Codex failed, and
   **Sign in** tries again. When it finishes, sign-in continues without
   another click. Before downloading, Enigma waits for your shell's answer
   (below), so a Codex it knows about is used instead.
3. Your browser opens OpenAI's sign-in page; finish there. While you do, the
   row reads **signing in** and offers **Cancel**.
4. When the row reads **connected** with your account email, ChatGPT becomes
   the preferred cloud provider and its model list loads. If you later choose
   another provider, **Use ChatGPT** switches back.
5. Choose **Cloud** in the mode and model menu (**⌘K**). Auto can also send
   requests to the preferred cloud provider; see
   [Cloud-Model-Selection.md](Cloud-Model-Selection.md).

### Which Codex Enigma uses

Enigma looks for `codex` in this order and uses the first executable it finds:

1. `AI_SPOTLIGHT_CODEX_PATH`, an absolute path for developers (for example in
   the Xcode scheme's Run environment).
2. Enigma's built-in Codex, once downloaded. Until this Enigma's pinned
   version is installed, the newest other built-in version is used (folders
   named `codex-<version>`; other names are ignored).
3. A Codex installed on this Mac: `/opt/homebrew/bin`, `/usr/local/bin`,
   `~/.local/bin`, then the folders Node version managers, npm and Bun install
   into (`~/.nvm/versions/node/*/bin` newest first, `~/.volta/bin`, fnm's
   `node-versions/*/installation/bin` under `~/.local/share/fnm` and
   `~/Library/Application Support/fnm`, `~/.asdf/shims`, `~/.npm-global/bin`
   and `~/.bun/bin`).
4. Where your shell finds it (`$SHELL -ilc 'command -v codex'`, interactive so
   zsh reads `~/.zshrc`, where version managers usually add themselves). Enigma
   asks at launch and before sign-in, in the background with a 5-second limit,
   and accepts only a path to an executable named `codex`. A definite answer,
   including "not found" (exit status 1, or 127 in fish), is kept for the
   session; a timeout or failure is asked again, and **Check sign-in status**
   asks again after a "not found". A timeout ends the shell and anything its
   profile started. Test hosts never ask.
5. The app's `PATH`.

So if you already have a working Codex, Enigma uses it and downloads nothing.
Enigma no longer looks inside `Codex.app` or `ChatGPT.app`.

### Built-in Codex

The first **Sign in** without a Codex downloads OpenAI's official Codex package
for this Mac's architecture from the
[openai/codex GitHub releases](https://github.com/openai/codex/releases)
(version 0.163.0; about 133 MB on Apple silicon, 145 MB on Intel), checks its
size and SHA-256 against the values pinned in Enigma, and installs it into
`~/Library/Application Support/AI Spotlight/Codex Runtime/codex-0.163.0/`. The
whole package is kept (`codex`, `codex-code-mode-host`, `rg` and the resources
folder), and OpenAI's Developer ID signature is left intact, so the Keychain
sign-in stays tied to OpenAI's code identity.

Before installing, Enigma lists the archive and rejects absolute paths, `..`,
and any top-level entry other than `bin`, `codex-package.json`, `codex-path`
and `codex-resources`; extracts it without the archive's owners; rejects any
link that leads outside the folder; checks `codex-package.json` (version,
architecture and `bin/codex` entry point) and that both binaries are
executable; and runs `codex --version` with a minimal environment and a time
limit. It then moves the folder into place; if another Enigma instance
already put this version there, Enigma keeps that copy and discards its own.
An install first removes `.staging-*` folders that an interrupted install left
behind and that haven't changed for a day (a newer one may belong to another
Enigma instance that is installing now).

New Codex versions ship with Enigma releases by updating the pin in
`CodexRuntimeInstaller.swift`. Every Enigma build on the Mac shares the
`Codex Runtime` folder. At launch, in the background, alongside the rest of
startup, Enigma removes day-old staging folders, and then:

- If the pinned version is installed, it removes `codex-<version>` folders
  older than the pin. Newer versions (another build's pin) and other names stay.
  Old folders are never removed right after an install, because a running app
  server or its code-mode host may still use one; new Codex processes always
  use the pinned folder.
- If only another built-in version is installed, it downloads the pinned one
  quietly, as a background activity: no UI and no new browser sign-in. The
  other copy keeps working meanwhile. If the upgrade fails, the same version
  isn't tried again for 24 hours.

![The ChatGPT and Claude rows on a Mac with neither tool installed](images/cloud-connections-not-installed-paper.png)

### Model and thinking capacity

The default model is GPT-5.6 Luna (`gpt-5.6-luna`). **Advanced cloud
settings** in Settings → Cloud and search lets you pick another model from the
list your account offers, enter a **Manual model ID**, and set
**Thinking capacity** (None, Minimal, Low, Medium, High, Extra High, Max, or
Ultra; the default is High). Which models and capacities work depends on your
plan and the model. If your account doesn't offer Luna, choose an available
model yourself; Enigma never silently switches to the first model in the list.

`/think` raises thinking capacity to at least Extra High for that message.

**Sign out** in the ChatGPT row signs Enigma out. Cloud sending then stays off
until you sign in again or choose another provider.

## Privacy and data handling

- Enigma starts `codex app-server` as a child process and talks to it over
  standard input and output. Sign-in uses the app server's browser OAuth flow;
  Enigma accepts only an `https://auth.openai.com` sign-in page.
- The app server runs with its own Codex home,
  `~/Library/Application Support/AI Spotlight/Codex`, and stores credentials in
  the macOS Keychain. Enigma never reads or copies the sign-in of the Codex CLI
  you use yourself, and signing out of Enigma doesn't affect it.
- The child process gets a minimal environment (`HOME`, a fixed `PATH` with
  the Codex executable's own folder first, plus `codex-path` for the built-in
  package, `TMPDIR`, `LANG`, and `CODEX_HOME`) and inherits no API keys. ChatGPT sign-in
  is forced, so an API-key login is rejected rather than billed.
- Each response runs in a new ephemeral thread with a read-only sandbox, an
  empty working folder, and no approvals. Codex history, web search, shell
  commands, plugins, hooks, apps, browser and computer use, image tools,
  memories, and multi-agent features are turned off. The thread is closed when
  the response ends, and **Stop** interrupts generation on the server.
- Downloading the built-in Codex sends only the HTTPS request to GitHub; no
  chats or account details. Nothing new is saved besides the package itself
  and, after a failed quiet upgrade, the failed version and time (so it waits
  a day before retrying).
- Enigma sends the conversation as a bounded JSON transcript, up to 32,768
  input tokens. Your chats stay in Enigma's own history; OpenAI's data policies
  apply to what Codex sends.

Two features use Codex differently, each with its own consent:

- Cloud File Mode uses a separate Codex connection with file tools limited to
  the files you choose. See [File-Mode.md](File-Mode.md).
- `/messages` gives Codex only Enigma's Messages tools and declines every
  native approval. See [Messages.md](Messages.md).

## How it works

| File | Responsibility |
| --- | --- |
| `Enigma/Cloud/CodexRuntimeInstaller.swift` | `CodexRuntime`: the pinned package per architecture, download, safe extraction, package checks, smoke test, install and old-version cleanup. |
| `Enigma/Cloud/CommandLineToolLocator.swift` | `CommandLineToolSearch` (the shared lookup folders, "looked in" text and `PATH` with the tool's folder) and `LoginShellToolLookup` (the cached login-shell question). Shared with Claude Code. |
| `Enigma/Cloud/CodexAppServer.swift` | `CodexRuntimeConfiguration` (executable lookup order, isolated environment, configuration overrides) and `CodexAppServer`, the JSON-RPC client that launches the app server, correlates requests, times out unanswered ones after 60 seconds, and fans out notifications. |
| `Enigma/Cloud/CodexSubscriptionClient.swift` | `CodexSubscriptionClient`: account status, browser sign-in and cancel, sign-out, paginated model discovery, and streaming a response (`thread/start`, `turn/start`, text deltas, `turn/interrupt`, `thread/unsubscribe`). |
| `Enigma/Cloud/CloudConnectionControls.swift` | `ChatGPTConnectionControls`, the row shared by Settings and welcome setup. |
| `Enigma/Cloud/CloudSettingsModel.swift` | Sign-in state, the Codex download before a first sign-in, the preferred provider and model, the one-time move of older saved defaults to Luna, and thinking capacity. |
| `Enigma/Cloud/CloudDomain.swift` | `CodexThinkingCapacity`. |
| `Enigma/Chat/ChatContext.swift` | The Codex context budget and transcript format. |

## Limitations

- The first sign-in without a Codex needs a download of about 133–145 MB.
- Enigma doesn't update the built-in Codex between Enigma releases.
- Plan limits and model availability come from your ChatGPT plan. This doesn't
  turn a ChatGPT subscription into OpenAI API credit, and it isn't the ChatGPT
  website.
- Responses are text only: no images are sent, and Codex's own tools are off.
  For how screenshots are handled, see [Screen-Skill.md](Screen-Skill.md).
- Sign-in needs a browser and your participation.

## Tests

`EnigmaTests/CodexSubscriptionTests.swift` mocks the JSON-RPC boundary (and
uses a real pipe for the app server) to cover the isolated environment and
disabled features, a missing CLI, **Sign in** downloading Codex and then
continuing into the browser sign-in, cancelling or failing that download and
retrying, request timeouts and disconnects, browser
sign-in, failure, unsafe sign-in URLs and cancellation, rejection of API-key
accounts, model pagination, the Luna default and its one-time migration,
thinking capacity, ephemeral streaming with conversation context, partial text
on failure, Stop, no fallback to stored API keys, sign-out, and context limits.
None of these tests need Codex, a ChatGPT login, or paid requests.

`EnigmaTests/CloudToolInstallTests.swift` covers the lookup order (override,
built-in runtime, system and version-manager folders, the login shell, `PATH`)
with temporary folders and an injected home and environment, the removed
app-bundle candidates, the "looked in" text, the login-shell question's
parsing, caching and timeout with an injected runner, `PATH` with the tool's
own folder, the pinned download, the fallback to an older built-in version,
launch-time cleanup and quiet upgrade, removal of stale staging folders, and
installing small locally built fixture archives: success, unexpected entries,
escaping, dangling and absolute links, a wrong `codex-package.json`, missing
binaries and a failed smoke test.
None of these tests need Codex, a ChatGPT login, the network, or paid requests.
