# Claude subscription via Claude Code

Enigma can chat through the Claude Code CLI using a Claude Pro or Max plan, in the same way that
**ChatGPT via Codex** uses a ChatGPT plan. The usage counts against the plan's Claude Code limits,
not API billing. The Anthropic API-key route is still a separately billed alternative, and neither
route is an automatic fallback for the other.

## Setup

1. Install [Claude Code](https://code.claude.com/docs/en/setup). Enigma looks in `~/.local/bin`,
   `~/.claude/local`, Homebrew's standard locations, and the launch environment's PATH. To use a
   different executable, set an absolute path in `AI_SPOTLIGHT_CLAUDE_PATH` in the Xcode Run environment.
2. Open **Settings → Cloud & Search → Claude Subscription · Claude Code**.
3. If Claude Code is already signed in with a Claude subscription, the account appears immediately.
   If it is not, choose **Sign in to Claude Code**. Enigma opens Terminal and runs `claude auth login --claudeai`,
   then checks the status every two seconds until the browser sign-in finishes, for up to five minutes.
4. Choose **Use Claude**, or select **Claude via Claude Code** as the preferred provider in Advanced
   Cloud Settings, then switch the panel to **Cloud**.

The model list contains the Claude Code aliases `sonnet` (the default), `opus`, `fable`, and `haiku`.
Each alias resolves to the newest model of that family that the plan offers. A full model name can
be entered as a manual model ID; it is shown as unverified. The **Effort** picker sends `--effort` to
Claude Code. **Model Default** leaves the choice to Claude Code. `/think` raises the effort to at
least High for that message.

## Authentication and data handling

- Enigma uses the Claude Code login already on this Mac and does not read or copy its tokens.
  Claude Code keeps the credentials in the macOS Keychain. Signing in or out in Terminal (`claude auth logout`)
  affects both Enigma and the CLI. To stop using Claude in Enigma without signing out, choose another provider.
- The account check runs `claude auth status` and accepts only a `claude.ai` subscription login.
  If the CLI uses Anthropic Console billing instead, Enigma shows an error and does not send requests.
- The child process gets a minimal environment: `HOME`, `USER`, `LOGNAME`, a fixed `PATH`, `TMPDIR`, and `LANG`.
  It inherits no `ANTHROPIC_API_KEY`, auth token, base URL, or Bedrock/Vertex settings.
- Each response is a separate `claude -p` process that runs in an empty working directory under
  `~/Library/Application Support/AI Spotlight/Claude Code`. It uses `--safe-mode` (no CLAUDE.md,
  skills, plugins, hooks, or custom agents), `--tools ""`, `--strict-mcp-config` with no MCP servers,
  `--disable-slash-commands`, and `--no-session-persistence`. Enigma's own system prompt replaces
  Claude Code's coding-agent prompt.
- Enigma sends the conversation on standard input in the same bounded JSON transcript format that the
  Codex route uses. The input limit is 32,768 tokens. Responses arrive as `stream-json` text deltas.
  Stop terminates the process. Anthropic's service-side data policies still apply.
- This route is text-only. Screenshots go to a vision-capable provider or are handled with OCR, and
  Cloud File Mode continues to use Codex.

## Verification

`AI-SpotlightTests/ClaudeCodeSubscriptionTests.swift` replaces the CLI with shell scripts. The tests cover the
process environment and flags, stream parsing across chunk boundaries, account states, the conversation
sent on standard input, error results, unexpected exits, Stop terminating the process, and settings
access and persistence. CI does not need Claude Code, a login, or paid requests.

Manual check: confirm the account appears in Settings, choose Use Claude, send a short Cloud message,
stop a second response partway through, and then switch providers and confirm Claude Code is no longer used.

## Keeping /Applications up to date

`scripts/install-app.sh` builds a signed Release copy from the current checkout and installs it as
`/Applications/Enigma.app`. If that copy is running, the script quits it first and then relaunches it.
The app is signed with the project's Apple Development team, like a run from Xcode, so macOS
permissions persist across updates. The unsigned verification product does not keep them.

```sh
scripts/install-app.sh                 # build, install, and launch
scripts/install-app.sh --no-launch     # build and install only
scripts/install-app.sh --install-hooks # reinstall after each commit or pull on main
scripts/install-app.sh --remove-hooks  # stop reinstalling automatically
```

The hooks are local `post-commit` and `post-merge` Git hooks and are never committed. They build in the
background only while `main` is checked out, and relaunch Enigma only if it was already running.
Output goes to `~/Library/Logs/Enigma-Install.log`. Only one build runs at a time. A commit made
during a build triggers a single follow-up build, so the installed app ends on the newest commit.
Set `ENIGMA_INSTALL_DIR` to install somewhere other than `/Applications`.
