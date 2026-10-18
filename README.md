# Enigma

Enigma is a native macOS assistant that opens from the menu bar or a global
shortcut. It runs local models with llama.cpp and cloud models from OpenAI,
Anthropic, Gemini, ChatGPT (through Codex), and Claude (through Claude Code),
and can work with web search, screenshots, selected text, attached files, and
Apple Messages.

## Build and test

Open `AI-Spotlight.xcodeproj` and run the shared `Enigma` scheme, or use the
verification helper:

```sh
scripts/verify-xcode.sh build
scripts/verify-xcode.sh test
scripts/verify-xcode.sh analyze
```

`scripts/install-app.sh` installs a signed `/Applications/Enigma.app`. See
[AGENTS.md](AGENTS.md) for repository guidelines and [docs/](docs) for feature
notes.

## Messages (`/messages`)

Type `/messages` in a message to let the model read, search, and send your
Apple Messages (iMessage, SMS, and RCS) for that request. For example:
`/messages what did Sam say about Saturday?` or
`/messages tell Alex I'm running 10 minutes late`.

Enigma shows every message it is about to send — each recipient and the exact
text — and sends only when you choose **Send**. See
[docs/Messages.md](docs/Messages.md) for the design, privacy details, and
limitations.

### Setup

Messages must be signed in on this Mac. Grant these permissions to **Enigma**
(the copy you run — `/Applications/Enigma.app` after `scripts/install-app.sh`,
or the Xcode build when running from Xcode):

| Permission | Needed for | Where to grant it |
| --- | --- | --- |
| **Full Disk Access** | Reading and searching Messages history (`~/Library/Messages/chat.db`, opened read-only) | System Settings → Privacy & Security → Full Disk Access. Turn on Enigma, or click **+** and choose Enigma.app. Quit and reopen Enigma afterwards. |
| **Automation → Messages** | Sending messages | macOS asks the first time you approve a send. If you declined, open System Settings → Privacy & Security → Automation, expand Enigma, and turn on Messages. |
| **Contacts** (optional) | Showing names instead of phone numbers, and finding people by name | macOS asks the first time you use `/messages`. To change it later, open System Settings → Privacy & Security → Contacts. |

Settings → General → Messages shows the status of each permission with a button
that opens the right pane. If a permission is missing when you use `/messages`,
Enigma explains which one and offers the same button.

macOS ties these permissions to the app's signature. A copy built with a
different signing identity (for example the unsigned build from
`scripts/verify-xcode.sh`) needs them granted again.

### Models

- **Local and Auto** keep Messages on this Mac. They need the `llama-server`
  runtime: Settings → Local Models → Install Local File Tools.
- **Cloud** sends what the model looks up (message text, names, and handles) to
  the selected provider. Enigma asks once per provider before the first cloud
  Messages request.
