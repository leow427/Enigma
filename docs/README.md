# Enigma documentation

Each feature page explains how to use the feature, what it sends where, how it
works in the code, its limitations, and which tests cover it.

## Features

| Page | What it covers |
| --- | --- |
| [Chat](Chat.md) | The main window, composer, streaming replies, activity and sources, chat history, and how much context each request carries |
| [Local models](Local-Model-Selection.md) | The bundled model catalogue, how Enigma picks the model for this Mac, and installing and managing it |
| [Cloud models](Cloud-Model-Selection.md) | Auto, Local, and Cloud modes, cloud providers, model compatibility, and context budgets |
| [Screen](Screen-Skill.md) | `/screen` and `/snapshot`, screenshot consent, and keeping Enigma out of screen sharing |
| [Selection Context](Selection-Context.md) | Asking about, editing, or translating text selected in another app |
| [File Mode](File-Mode.md) | Attaching files and folders, reviewed local edits, and undo |
| [Web Search](Web-Search.md) | Brave Search, automatic and `/search` lookups, and sources |
| [Messages](Messages.md) | `/messages`: reading, searching, and sending Apple Messages, with setup |
| [Slash commands](Slash-Commands.md) | Every composer command, how commands combine, and commands recognized from your wording |
| [Welcome and Settings](Welcome-and-Settings.md) | Opening Enigma, first-run setup, the Settings window, and keyboard shortcuts |

## Guides

| Page | What it covers |
| --- | --- |
| [ChatGPT setup](ChatGPT-Setup.md) | Using a ChatGPT plan through the Codex CLI |
| [Claude Code setup](Claude-Code-Setup.md) | Using a Claude plan through the Claude Code CLI |
| [Updating the model catalogue](Updating-the-Model-Catalogue.md) | The release checklist for adding or refreshing local models |
| [Testing](Testing.md) | The verification helper, CI, snapshot tests, and opt-in real-model checks |
| [Distribution](Distribution.md) | Running from Xcode, installing a signed copy, signing, and entitlements |
| [Updates](Updates.md) | Automatic updates through Sparkle, the What's new? button, moving the app into Applications, the update signing key, and publishing a release with `scripts/release.sh` |
| [Reviewer](reviewer.md) | The instructions for the read-only reviewer agent that audits a feature diff |

## Design and history

- [design/UI-Style.md](design/UI-Style.md) is the visual-design reference for
  every screen.
- [design/ui-revamp/](design/ui-revamp/README.md) is the design record for the
  Paper and Ink interface, with mockups and screenshots.
- [history/](history/README.md) keeps earlier reports. They describe the app as
  it was then, not as it is now.
- [superpowers/](superpowers/) keeps the design specs and implementation plans
  written before recent features were built. Like history, they describe the
  plan at the time.
- [release-notes/](release-notes/) has the notes for each release, which
  `scripts/release.sh` publishes with the update and the app bundles for its
  What's new? sheet. See [Updates](Updates.md).
