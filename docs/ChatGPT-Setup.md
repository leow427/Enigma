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
(version 0.164.0; about 136 MB on Apple silicon, 147 MB on Intel), checks its
size and SHA-256 against the values pinned in Enigma, and installs it into
`~/Library/Application Support/AI Spotlight/Codex Runtime/codex-0.164.0/`. The
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

The same quiet upgrade is also checked about two minutes after launch and then
once a day while Enigma runs (never the cleanup, which stays at launch). That
check also covers a Codex installed on this Mac, such as Homebrew's: OpenAI
serves Codex's model list per Codex version, so an older Codex shows older
models. Enigma quietly installs its pinned Codex the same way, with the same
24-hour wait after a failure, when all of these hold:

- You are signed in to ChatGPT in Enigma. Codex isn't even started for this
  check unless ChatGPT is your chosen provider, you chose a ChatGPT model, or
  Enigma has a ChatGPT model list cached.
- The Codex Enigma would use is a system install (not the developer override
  or a built-in copy) whose `codex --version` reports an older version than the
  pin on its `codex-cli` line (for example `codex-cli 0.153.4`).
- That Codex satisfies the code requirement
  `identifier "codex" and anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"`:
  the `codex` identifier, validly signed with OpenAI's Developer ID, like the
  pinned package. For an npm or Homebrew install, where `codex` is a Node
  script, Enigma checks the native binary it runs from the platform package.

Only one quiet install runs at a time, so a launch upgrade still downloading
makes the check skip. From then on the built-in Codex comes first in the lookup
order. People who don't use ChatGPT in Enigma never get this download.

Enigma's Codex keeps its sign-in in the macOS Keychain, and Keychain access
follows the code identity of the binary that created the item, not the Codex
home. The requirement is meant to keep the switch silent: a Codex with the
same identifier and team reads the item without a Keychain prompt, so you stay
signed in. A Codex signed by anyone else (for example one built from source) is
left alone.

A Codex app server that is already running keeps its binary until nothing is in
flight (no startup, request, reply streaming or sign-in waiting); its next
request then starts the new Codex. This happens whenever the lookup finds a
different Codex than the one running, so it also covers the launch upgrade
finishing after a server started. If a reply is still streaming on the old
Codex when the daily check would refresh the model list, it skips the refresh
and tries again in an hour, so the old Codex's list isn't cached. See
[Cloud-Model-Selection.md](Cloud-Model-Selection.md#daily-refresh).

![The ChatGPT and Claude rows on a Mac with neither tool installed](images/cloud-connections-not-installed-paper.png)

### Model and thinking capacity

Until you choose a model, Enigma uses the one Codex marks as its default
(`isDefault` in `model/list`), or the first model listed if none is marked, or
GPT-5.6 Luna (`gpt-5.6-luna`) before any list has loaded. This default isn't
saved, so it follows Codex as the list changes. **Advanced cloud settings** in
Settings → Cloud and search lets you pick another model from the list your
account offers, enter a **Manual model ID**, and set **Thinking capacity**
(None, Minimal, Low, Medium, High, Extra High, Max, or Ultra; the default is
High). Which models and capacities work depends on your plan and the model. A
model you chose is kept even if a later list omits it; Enigma never replaces
your choice. When File Mode hands a draft to Cloud mode, the model it checked
is used; without a chosen model that is Codex's default, which is shown but
not saved as a choice.

Every model Codex lists (hidden ones are left out) is compatible. Reviewed
models use their published limits; others use a conservative 128,000-token
context and 32,000-token output. See
[Cloud-Model-Selection.md](Cloud-Model-Selection.md#context-budgets).

### Screenshots

A model whose `model/list` entry includes `"image"` in `inputModalities` (the
app server's default when the field is missing) takes screenshots, under the
same permission as the API providers (see [Screen-Skill.md](Screen-Skill.md)).
The screenshot goes in the `turn/start` input as
`{"type":"image","url":"data:image/jpeg;base64,…","detail":null}` before the
text item; Enigma never writes it to disk. A model list cached by an earlier
Enigma didn't record input types, so its models count as text-only until the
next refresh.

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
  commands, plugins, hooks, apps, browser and computer use, image tools
  (generating images and viewing local image files; a screenshot you send is
  part of your message, not a tool), memories, and multi-agent features are
  turned off. The thread is closed when
  the response ends, and **Stop** interrupts generation on the server.
- Downloading the built-in Codex sends only the HTTPS request to GitHub; no
  chats or account details. Nothing new is saved besides the package itself
  and, after a failed quiet upgrade, the failed version and time (so it waits
  a day before retrying).
- The daily refresh asks only for the sign-in status and the model list; it
  never starts a turn.
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
| `Enigma/Cloud/CodexRuntimeInstaller.swift` | `CodexRuntime`: the pinned package per architecture, download, safe extraction, package checks, smoke test, install, old-version cleanup, and the daily check (`maintainDaily`, including the system Codex's version). |
| `Enigma/Cloud/SubscriptionModelRefresh.swift` | `DailySchedule` and `SubscriptionModelRefresh`: the daily Codex check and model-list refresh. |
| `Enigma/Cloud/CommandLineToolLocator.swift` | `CommandLineToolSearch` (the shared lookup folders, "looked in" text and `PATH` with the tool's folder) and `LoginShellToolLookup` (the cached login-shell question). Shared with Claude Code. |
| `Enigma/Cloud/CodexAppServer.swift` | `CodexRuntimeConfiguration` (executable lookup order, isolated environment, configuration overrides) and `CodexAppServer`, the JSON-RPC client that launches the app server, writes to it off the actor (`CodexPipeWriter`, so a Codex that stops reading can't block timeouts or Stop; a failed write disconnects), correlates requests, times out unanswered ones after 60 seconds, fans out notifications, restarts on a new Codex once idle, and checks File Mode support again for a new binary. |
| `Enigma/Cloud/CodexSubscriptionClient.swift` | `CodexSubscriptionClient`: account status, browser sign-in and cancel, sign-out, paginated model discovery (input types and default), the default model, and streaming a response (`thread/start`, `turn/start` with text and any screenshot, text deltas, `turn/interrupt`, `thread/unsubscribe`). |
| `Enigma/Cloud/CloudConnectionControls.swift` | `ChatGPTConnectionControls`, the row shared by Settings and welcome setup. |
| `Enigma/Cloud/CloudSettingsModel.swift` | Sign-in state, the Codex download before a first sign-in, the preferred provider and model (Codex's default until you choose), the one-time clearing of older saved defaults, the quiet daily list refresh, and thinking capacity. |
| `Enigma/Cloud/CloudDomain.swift` | `CodexThinkingCapacity`, and `CodexListedModels`, Codex's last list for checks that know only a model ID. |
| `Enigma/Chat/ChatContext.swift` | The Codex context budget and transcript format. |

## Limitations

- The first sign-in without a Codex needs a download of about 136–147 MB, and
  so does the first daily check for someone signed in with an older system
  Codex.
- Enigma doesn't update the built-in Codex between Enigma releases.
- Plan limits and model availability come from your ChatGPT plan. This doesn't
  turn a ChatGPT subscription into OpenAI API credit, and it isn't the ChatGPT
  website.
- Codex's own tools are off. Screenshots reach only models Codex lists as
  taking images; see [Screen-Skill.md](Screen-Skill.md).
- Sign-in needs a browser and your participation.

## Tests

`EnigmaTests/CodexSubscriptionTests.swift` mocks the JSON-RPC boundary (and
uses a real pipe for the app server) to cover the isolated environment and
disabled features, a missing CLI, **Sign in** downloading Codex and then
continuing into the browser sign-in, cancelling or failing that download and
retrying, request timeouts and disconnects, browser
sign-in, failure, unsafe sign-in URLs and cancellation, rejection of API-key
accounts, model pagination with input types and the default flag, old caches
without them, the default from Codex and the one-time clearing of saved
defaults, thinking capacity, the exact `turn/start` input with and without a
screenshot, ephemeral streaming with conversation context, partial text on
failure, Stop, no fallback to stored API keys, sign-out, and context limits.
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

`EnigmaTests/SubscriptionModelRefreshTests.swift` covers the daily check: the
quiet install over an older, OpenAI-signed system Codex (and not over a newer,
equal, unreadable or unsigned one, or for someone who doesn't use ChatGPT), the
24-hour wait after a failed install, one quiet install at a time, built-in
copies first, parsing `codex --version` with stray warnings, finding the system
Codex, the app server switching to a new Codex only when idle (including when
the lookup finds a new one, and not during startup), and surviving a Codex that
exits while a large request is written.
