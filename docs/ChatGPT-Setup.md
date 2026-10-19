# ChatGPT via Codex

Enigma can chat through your ChatGPT plan by running OpenAI's Codex CLI on this
Mac. Usage counts against the plan's Codex allowance, not API billing, and the
sign-in belongs to Enigma alone. The OpenAI API-key route is a separately billed
alternative; neither route falls back to the other.

## Setup

1. Install the [Codex CLI](https://learn.chatgpt.com/docs/cli). Enigma looks
   for `codex` in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, inside
   `/Applications/Codex.app` and `/Applications/ChatGPT.app`, and then on the
   app's `PATH`. To use another copy, set `AI_SPOTLIGHT_CODEX_PATH` to its
   absolute path (for example in the Xcode scheme's Run environment).
2. Open **Settings → Cloud and search → Subscriptions → ChatGPT**, or the
   **Connect what you use** step of welcome setup. If Codex isn't found, the row
   says so and offers **Codex installation instructions** and
   **Check sign-in status**; **Sign in** stays off until Codex is installed.
3. Choose **Sign in**. Your browser opens OpenAI's sign-in page; finish there.
   While you do, the row reads **signing in** and offers **Cancel**.
4. When the row reads **connected** with your account email, ChatGPT becomes
   the preferred cloud provider and its model list loads. If you later choose
   another provider, **Use ChatGPT** switches back.
5. Choose **Cloud** in the mode and model menu (**⌘K**). Auto can also send
   requests to the preferred cloud provider; see
   [Cloud-Model-Selection.md](Cloud-Model-Selection.md).

![The ChatGPT row during setup](design/ui-revamp/screenshots/phase-10/welcome-connections-paper.png)

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
- The child process gets a minimal environment (`HOME`, a fixed `PATH`,
  `TMPDIR`, `LANG`, and `CODEX_HOME`) and inherits no API keys. ChatGPT sign-in
  is forced, so an API-key login is rejected rather than billed.
- Each response runs in a new ephemeral thread with a read-only sandbox, an
  empty working folder, and no approvals. Codex history, web search, shell
  commands, plugins, hooks, apps, browser and computer use, image tools,
  memories, and multi-agent features are turned off. The thread is closed when
  the response ends, and **Stop** interrupts generation on the server.
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
| `Enigma/Cloud/CodexAppServer.swift` | `CodexRuntimeConfiguration` (executable lookup, isolated environment, configuration overrides) and `CodexAppServer`, the JSON-RPC client that launches the app server, correlates requests, times out unanswered ones after 60 seconds, and fans out notifications. |
| `Enigma/Cloud/CodexSubscriptionClient.swift` | `CodexSubscriptionClient`: account status, browser sign-in and cancel, sign-out, paginated model discovery, and streaming a response (`thread/start`, `turn/start`, text deltas, `turn/interrupt`, `thread/unsubscribe`). |
| `Enigma/Cloud/CloudConnectionControls.swift` | `ChatGPTConnectionControls`, the row shared by Settings and welcome setup. |
| `Enigma/Cloud/CloudSettingsModel.swift` | Sign-in state, the preferred provider and model, the one-time move of older saved defaults to Luna, and thinking capacity. |
| `Enigma/Cloud/CloudDomain.swift` | `CodexThinkingCapacity`. |
| `Enigma/Chat/ChatContext.swift` | The Codex context budget and transcript format. |

## Limitations

- The Codex CLI must be installed on this Mac.
- Plan limits and model availability come from your ChatGPT plan. This doesn't
  turn a ChatGPT subscription into OpenAI API credit, and it isn't the ChatGPT
  website.
- Responses are text only: no images are sent, and Codex's own tools are off.
  For how screenshots are handled, see [Screen-Skill.md](Screen-Skill.md).
- Sign-in needs a browser and your participation.

## Tests

`EnigmaTests/CodexSubscriptionTests.swift` mocks the JSON-RPC boundary (and
uses a real pipe for the app server) to cover the isolated environment and
disabled features, a missing CLI, request timeouts and disconnects, browser
sign-in, failure, unsafe sign-in URLs and cancellation, rejection of API-key
accounts, model pagination, the Luna default and its one-time migration,
thinking capacity, ephemeral streaming with conversation context, partial text
on failure, Stop, no fallback to stored API keys, sign-out, and context limits.
None of these tests need Codex, a ChatGPT login, or paid requests.
