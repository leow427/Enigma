# Enigma

Enigma is a native macOS assistant that lives in the menu bar. Press **Option
and Control** together in any app to open it, ask a question, and get an answer
from a model running on your Mac or from a cloud provider you connect.

![Enigma's main window](docs/design/ui-revamp/screenshots/phase-10/main-page-paper.png)

## What it does

- **Local or cloud, your choice.** Run a recommended local model through
  llama.cpp, or connect OpenAI, Anthropic, or Gemini with an API key, a ChatGPT
  plan through Codex, or a Claude plan through Claude Code. **Auto** picks
  between local and cloud for each request.
- **Ask about what you're looking at.** Select text in another app and tap
  **Option** twice to ask about it, translate it, or `/edit` it and paste the
  revision back. Use `/screen` or `/snapshot` to ask about your screen.
- **Work with files.** Attach files or folders and let a local model, or Codex
  with your permission, read and edit them. Every change can be reviewed and
  undone.
- **Search and Messages.** Look things up with Brave Search, and use
  `/messages` to read, search, and send Apple Messages after you approve each
  send.
- **Private by default.** Chat history is saved only on this Mac. Enigma asks
  before sending a screenshot or protected files to a cloud provider, and keeps
  its windows out of screen sharing.

See [docs/](docs/README.md) for how each feature works.

## Requirements

- macOS 26 or later.
- Xcode 26 to build.
- For local models: enough memory and disk for the model you pick. Enigma
  recommends models that fit your Mac.
- Optional: API keys or the Codex or Claude Code CLI for cloud models, and a
  Brave Search API key for web search.

## Install

1. Download the latest `Enigma-<version>.zip` from
   [Releases](https://github.com/leow427/Enigma/releases).
2. Unzip it and drag `Enigma.app` into Applications. If you open it from
   somewhere else, Enigma offers to move itself there, because it can only
   update itself from Applications.
3. The first time, right-click `Enigma.app` and choose **Open** (or allow it in
   System Settings → Privacy & Security), because Enigma is not notarized.

Later versions arrive by themselves: Enigma checks once a day, downloads the
update, and installs it when it quits or when you choose **Restart to Update**
in its menu. See [docs/Updates.md](docs/Updates.md).

## Build and run

Open `Enigma.xcodeproj` and run the `Enigma` scheme. To install a signed copy
as `/Applications/Enigma.app`:

```sh
scripts/install-app.sh
```

Some features need macOS permissions: Accessibility for the shortcuts and
selected text, Screen Recording for `/screen`, and Full Disk Access for
`/messages`. Setup and **Settings → General** show their status. See
[docs/Distribution.md](docs/Distribution.md) for signing and installing, and
[docs/Welcome-and-Settings.md](docs/Welcome-and-Settings.md) for first-run
setup.

## Tests

```sh
scripts/verify-xcode.sh build
scripts/verify-xcode.sh test
scripts/verify-xcode.sh analyze
```

See [docs/Testing.md](docs/Testing.md) for details and
[AGENTS.md](AGENTS.md) for contribution guidelines.

## Project layout

| Path | Contents |
| --- | --- |
| `Enigma/` | The app: `App/` (windows, panel, settings, shortcuts), `Chat/`, `Cloud/`, `LocalInference/`, `Screen/`, `Files/`, `Search/`, `Messages/`, `Resources/` |
| `EnigmaTests/` | The XCTest suite |
| `Packages/LlamaBridge/` | Swift package wrapping the pinned llama.cpp framework |
| `scripts/` | Verification, install, icon, and File Mode evaluation scripts |
| `docs/` | Feature docs, guides, the design reference, and history |

## License

Enigma is freeware, not open source: it is free to use, personally or at work,
under the [Enigma Freeware License](LICENSE). Share links to the official
[releases page](https://github.com/leow427/Enigma/releases) rather than hosting
copies yourself. Modifying, reusing, or redistributing the app or its source
code is not permitted.

Third-party components keep their own licenses, listed in
[Enigma/Resources/ThirdPartyNotices.txt](Enigma/Resources/ThirdPartyNotices.txt).
