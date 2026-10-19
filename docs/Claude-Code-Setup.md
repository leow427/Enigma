# Claude via Claude Code

Enigma can chat through your Claude Pro or Max plan by running the Claude Code
CLI on this Mac. Usage counts against the plan's Claude Code limits, not API
billing. The Anthropic API-key route is a separately billed alternative; neither
route falls back to the other.

## Setup

1. Install [Claude Code](https://code.claude.com/docs/en/setup). Enigma looks
   for `claude` in `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, and
   `/usr/local/bin`, and then on the app's `PATH`. To use another copy, set
   `AI_SPOTLIGHT_CLAUDE_PATH` to its absolute path (for example in the Xcode
   scheme's Run environment).
2. Open **Settings → Cloud and search → Subscriptions → Claude**, or the
   **Connect what you use** step of welcome setup. If Claude Code isn't found,
   the row says so and offers **Claude Code installation instructions** and
   **Check sign-in status**; **Sign in** stays off until it is installed.
3. If Claude Code is already signed in with a Claude subscription, the row reads
   **connected** with your email and plan. Otherwise choose **Sign in**: Enigma
   opens Terminal, which runs `claude auth login --claudeai`, and you finish in
   the browser. Enigma checks the sign-in every two seconds for up to five
   minutes; **Cancel** stops waiting. Once signed in, Claude becomes the
   preferred cloud provider and its models load.
4. If another provider is selected, choose **Use Claude**. The row then reads
   **connected · selected for cloud**.
5. Choose **Cloud** in the mode and model menu (**⌘K**). Auto can also send
   requests to the preferred cloud provider; see
   [Cloud-Model-Selection.md](Cloud-Model-Selection.md).

![The Claude row during setup](design/ui-revamp/screenshots/phase-10/welcome-connections-paper.png)

### Model and effort

The model list holds Claude Code's aliases: **Sonnet (latest)** (the default),
**Opus (latest)**, **Fable (latest)**, and **Haiku (latest)**. Each resolves to
the newest model of that family your plan offers. You can type a full model
name in **Manual model ID** under **Advanced cloud settings**; it is shown as
unverified.

**Effort** (Model Default, Low, Medium, High, Extra High, or Max) is passed to
Claude Code as `--effort`; Model Default leaves the choice to Claude Code.
`/think` raises effort to at least High for that message.

### Disconnecting

Enigma shares the Claude Code sign-in on this Mac. To stop using Claude in
Enigma, choose another provider. Running `claude auth logout` in Terminal signs
out of both Enigma and the CLI.

## Privacy and data handling

- Enigma never reads or copies Claude Code's credentials; Claude Code keeps them
  and Enigma only runs the CLI.
- The account check runs `claude auth status` and accepts only a `claude.ai`
  subscription sign-in. If Claude Code is signed in with Anthropic Console
  billing, Enigma shows an error and sends nothing.
- The CLI runs with a minimal environment (`HOME`, `USER`, `LOGNAME`, a fixed
  `PATH`, `TMPDIR`, and `LANG`). It inherits no `ANTHROPIC_API_KEY`, auth
  token, base URL, or Bedrock or Vertex settings.
- Each response is a separate `claude -p` process in an empty working folder
  under `~/Library/Application Support/AI Spotlight/Claude Code`. It runs with
  `--safe-mode` (no CLAUDE.md files, skills, plugins, hooks, or custom agents),
  `--tools ""`, `--strict-mcp-config` with no MCP servers,
  `--disable-slash-commands`, and `--no-session-persistence`. Enigma's system
  prompt replaces Claude Code's own.
- Enigma sends the conversation on standard input as a bounded JSON transcript,
  up to 32,768 input tokens, and reads streamed text deltas. **Stop**
  terminates the process. Anthropic's data policies apply.

With `/messages`, the process instead gets an in-process MCP server that Enigma
answers over Claude Code's stream-json control protocol, so no helper process
or network listener is involved. Built-in tools stay off and only Enigma's
Messages tools are allowed. See [Messages.md](Messages.md).

## How it works

| File | Responsibility |
| --- | --- |
| `Enigma/Cloud/ClaudeCodeSubscriptionClient.swift` | `ClaudeCodeRuntime` (executable lookup, environment, chat and tool-mode arguments, the Terminal sign-in script), `ClaudeCodeProcess`, `ClaudeCodeStreamParser`, and `ClaudeCodeSubscriptionClient` (account status, the model aliases, streaming). Also `ClaudeCodeEffort`. |
| `Enigma/Cloud/CloudToolCalling.swift` | `ClaudeCodeToolMode`, which serves Enigma's MCP server for tool requests such as `/messages`. |
| `Enigma/Cloud/CloudConnectionControls.swift` | `ClaudeCodeConnectionControls`, the row shared by Settings and welcome setup. |
| `Enigma/Cloud/CloudSettingsModel.swift` | Account state, the sign-in polling, the preferred provider and model, and effort. |
| `Enigma/Chat/ChatContext.swift` | The Claude Code context budget, which leaves room for the CLI's own prompt text. |

## Limitations

- Claude Code must be installed and signed in with a Claude subscription.
- Plan usage limits apply.
- Responses are text only: no images are sent. For how screenshots are handled,
  see [Screen-Skill.md](Screen-Skill.md). Cloud File Mode uses ChatGPT via
  Codex, not Claude; see [File-Mode.md](File-Mode.md).
- Sign-in happens in Terminal and the browser and needs your participation.

## Tests

`EnigmaTests/ClaudeCodeSubscriptionTests.swift` replaces the CLI with shell
scripts. It covers the process environment and flags, `/think` raising effort,
stream parsing across chunk boundaries, error results and invalid output,
account states, a missing CLI, the conversation sent on standard input,
results without deltas, signed-out and unexpected exits, Stop terminating the
process, settings and the default model, the Terminal sign-in flow, and the
context budget. `EnigmaTests/MessagesToolCallingTests.swift` covers the tool
mode's arguments and MCP handling. None of these tests need Claude Code, a
login, or paid requests.
