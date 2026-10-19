# Inferred commands — design

Status: approved design, not yet implemented. Date: 2026-10-19.

## Goal and users

Slash commands turn a tool on for one message. People forget them, and plain
requests then fail in confusing ways. In one real chat:

1. `/messages check what Sam texted me last` read the latest
   message correctly.
2. The follow-up `send her a message saying "hey, what's up"` had no command,
   so the model had no Messages tools and replied that it couldn't send
   messages.
3. `/messages send her the message, you should be able to` sent it.

This change lets Enigma recognize the command from the wording of the typed
draft, show what it recognized as a chip in the composer before sending, and
then behave exactly as if the command had been typed. Typed commands still
work and always win, for people who want to be explicit.

Success: "what did Sam text me last?", "text Alex that I'm running late" and a
follow-up like "send her a message saying …" after a Messages turn all use
Messages without a typed command. A `messages` chip shows this before sending
and can be clicked away. Nothing is inferred from selected text, files,
screenshots, earlier messages or tool results. Recognition adds no model call
and no noticeable typing latency.

## Decisions

1. **Recognize commands deterministically, on this Mac, from the typed draft
   only.** Fixed English patterns, like automatic web search
   (`WebSearchPolicy`). No extra model call.
   - Rejected: always giving the model every tool. Every chat would run the
     slower tool loop with a larger prompt. Small local models call tools
     unprompted. Cloud mode could read Messages without a clear request.
   - Rejected: a model classifier before each message. It adds a model call
     to every message, against Enigma's low-latency aim.
2. **Show inferred commands as chips before sending.** A chip appears in the
   composer bar while typing. Clicking it turns that inference off for the
   current draft. The chips and Send use the same resolution function, so
   they can't disagree.
3. **Commands that are inferred:** `messages`, `search` (the existing automatic
   search, now shown as a chip), `think`, and with Selection Context attached
   only, `edit` and `translate`.
4. **`/screen` and `/snapshot` are never inferred.** They capture the screen
   and stay typed-only.
5. **Messages carries into follow-ups on a looser cue.** If the previous
   accepted request in this chat used Messages (typed or inferred), a draft
   with a looser messaging cue also infers `messages`. An unrelated follow-up
   goes back to normal chat.
6. **Typed commands win, and inference never causes an error.** An inferred
   command that would conflict is dropped silently and gets no chip.
7. **One new setting**, "Recognize commands from your wording", on by default.
   It controls `messages`, `think`, `edit` and `translate`. The `search` chip
   keeps following the existing automatic-search setting.

## Behaviour

### What is recognized

Each matcher reads the draft with typed slash commands removed, quoted,
backticked and code-block text removed (as `WebSearchPolicy.questionText`
does), curly apostrophes normalized, and lowercased.

| Inferred | Recognized when | Not recognized |
| --- | --- | --- |
| `messages` (read) | A read verb plus a messaging word: "what did Sam text me", "did Mom message me", "check my messages from …", "any new texts from …", "what did X say in our chat / on iMessage", "last text from …" | "error message", "commit message", "what does this message mean", "write a message to my landlord" (drafting text without sending), "message queue" |
| `messages` (send) | A send verb aimed at a person: "text Alex that …", "send X a message/text saying …", "message Sam …", "reply to Mom …", "tell X on iMessage/by text …", "iMessage X …" | "send me a summary", "tell me about …", "send an email to …" |
| `messages` (follow-up) | Previous accepted request in this chat used Messages, and the draft has a looser cue: send, reply, text, message, tell her/him/them, "what about …", "what else did …" | Any draft without one of these cues |
| `search` | `WebSearchPolicy.needsFreshInformation` is true, the automatic-search setting is on, and a Brave key is saved | Everything that doesn't search automatically today |
| `think` | "think hard / harder / carefully / deeply", "take your time", "step by step", "reason it through" | "I think …", "what do you think …" |
| `edit` | Selection Context attached, and a rewrite request about it: "rewrite this", "make it shorter / longer / more formal / friendlier", "fix the grammar / spelling / typos", "reword", "proofread", "shorten / tighten this" | No selection attached; questions about the selection ("what does this mean?") |
| `translate` | Selection Context attached, and "translate (this/it) (to/into X)" | No selection attached |
| `screen`, `snapshot` | Never | — |

The pattern lists above are the minimum. The implementation may add phrasings
that meet the same intent, each with a test. Patterns are English only.

### Chips

- Inferred commands appear as chips in the composer bar, after the route
  indicator (`● local` / `○ cloud`), in the main-window composer and the
  compact selection panel. Order: `messages`, `search`, `think`, `edit`,
  `translate`.
- A chip reads as the command word in the composer's monospace type with a
  small `×`, using palette tokens per `docs/design/UI-Style.md`.
- Chips update on every change to the draft. Typed commands get no chip; they
  are already highlighted in the text.
- Clicking a chip dismisses that inference for the current draft. Dismissals
  reset when the draft is sent or becomes empty.
- Accessibility: each chip is a button labeled "Recognized command:
  \<command\>", with the hint "Turns it off for this message".

### Resolution and conflicts

Applied in this order:

1. Start from the typed commands (`ComposerCommands`).
2. Add inferred commands that are allowed (setting on, selection attached for
   `edit` and `translate`) and not dismissed.
3. Drop conflicting inferred commands, never typed ones:
   - Files attached: drop inferred `messages` and `search`.
   - Screenshot attached: drop inferred `messages`.
   - Typed `/search`, `/screen` or `/snapshot`: drop inferred `messages`.
   - Inferred or typed `messages`: drop inferred `search`. Message contents
     must never become a web search query.
   - Typed `/messages`: drop inferred `search` (already true today).
   - Typed `/translate` or inferred `translate`: drop inferred `edit`
     (translation stays read-only).
4. Typed conflicts keep today's errors (`fileConflict`, `messagesConflict`).

### Effect of an inferred command

An inferred command behaves exactly like its typed form:

- `messages` → `ComposerSubmission.messages(prompt:)`. Full Disk Access
  preflight, the per-provider cloud disclosure, Auto staying local, and the
  send-approval card all apply unchanged.
- `think`, `edit`, `translate` → prefixed onto `submissionPrompt` the same
  way typed ones are, so `ThinkCommand` and `SelectionResponseMode` see them.
- `search` → `searchEnabled: true`. When the search chip is dismissed,
  `searchEnabled` is `false` and the automatic check doesn't run again later.

### Settings

**Settings → General** gains a switch, "Recognize commands from your wording",
backed by the user default `composer.inferCommands` (default `true`). With it
off, only `search` can still be inferred, controlled by its own existing
setting.

## Architecture

### `Enigma/App/ComposerIntent.swift` — the one resolution function

A pure, synchronous, `Sendable` value type. No AppKit, no globals.

```swift
struct ComposerIntent: Equatable {
  struct Context: Equatable {
    var draft: String
    var hasSelection = false
    var hasFileSelection = false
    var hasScreenshot = false
    var previousTurnUsedMessages = false
    var infersCommands = true        // composer.inferCommands
    var searchesAutomatically = false // automatic search on and a key saved
    var dismissed: Set<SlashCommand> = []
  }
  let typed: ComposerCommands
  /// The inferred commands that will apply, in chip order.
  let inferred: [SlashCommand]
  // Effective flags: typed || inferred.
  var messages: Bool; var search: Bool; var think: Bool; var edit: Bool; var translate: Bool
  var submissionPrompt: String
  static func resolve(_ context: Context, now: Date = Date()) -> ComposerIntent
}
```

`ComposerSubmission.plan` takes the resolved `ComposerIntent` (or builds it
from an extended `Context`) instead of building `ComposerCommands` itself. The
composer views get `inferred` to draw chips. Both call `resolve` with the same
context, so the chip and Send agree.

### Matchers, kept with their features

- `Enigma/Messages/MessagesIntentPolicy.swift`: `isRequested(_ text:)` and
  `isFollowUp(_ text:)`.
- Think: a `ThinkCommand.isRequested(by:)` beside `ThinkCommand`.
- Edit and translate: a `SelectionIntentPolicy` beside `SelectionResponseMode`
  in `Enigma/Chat/ConversationContext.swift`, returning `.edit`, `.translate`
  or `nil`.
- Search: `WebSearchPolicy.needsFreshInformation`, unchanged.

Each matcher compiles its regular expressions once (`static let`), as
`WebSearchPolicy` does. Resolving a draft must stay well under a millisecond.

### State

- **Dismissed chips:** `Set<SlashCommand>` held by the composer owner
  (`AppShellView` / shell state). Cleared when the draft is sent or becomes
  empty.
- **Previous turn used Messages:** an in-memory flag on `LocalChatViewModel`,
  set when a Messages request is accepted, cleared when a non-Messages request
  is accepted, on a new chat, and when switching chats. Never saved.
- **Setting:** `composer.inferCommands` in `UserDefaults.standard`.

### Call sites to update

- `AppShellView.submitDraft` and `submitScreenAttachment` use the resolved
  intent.
- `ScreenComposerCoordinator`, which builds `ComposerCommands` too, keeps
  typed-only behaviour for captures (screen is never inferred). It must not
  start inferring `messages` alongside a capture.
- `LocalChatViewModel.shouldSearch`: the `searchEnabled` passed in from a
  resolved intent is final. The automatic re-check stays only for paths that
  don't resolve an intent.
- `EnigmaComposer` and `EnigmaCompactPanel` draw the chips.
- `SettingsView` (General) adds the switch.

## Privacy and safety

- Only the typed draft can infer a command. Selection text, files, OCR,
  screenshots, earlier messages and tool results are never inspected. The
  follow-up rule reads one in-memory flag, not earlier message text.
- Quoted and backticked text stays literal, as for typed commands.
- Sending still needs the approval card for every message. Cloud Messages
  still needs the one-time per-provider disclosure. Auto still keeps Messages
  on this Mac.
- The chip makes every inferred tool visible before anything runs.

## Docs to update

- `docs/Slash-Commands.md`: a "Recognized commands" section (what's inferred,
  chips, conflicts, the setting), and the screen/snapshot exception.
- `docs/Messages.md`: using Messages without `/messages`, and follow-ups.
- `docs/Web-Search.md`: the `search` chip and dismissing it.
- `docs/Welcome-and-Settings.md`: the new General switch.

## Testing

All offline and deterministic. No test reads `chat.db` or sends a message.

- `EnigmaTests/ComposerIntentTests.swift`:
  - Table-driven positive and negative phrases for each matcher, including
    every example in the table above, quoted and backticked commands, curly
    apostrophes, and screen phrases ("what's on my screen") never inferring.
  - `edit` and `translate` inferred only with a selection.
  - Every conflict rule, typed winning over inferred, and dismissals.
  - Follow-up carry-over on and off, and the setting turned off.
- `ComposerSubmission.plan` tests updated for inferred `messages`, `think`,
  `edit` and `translate`, and a dismissed `search`.
- `LocalChatViewModel`: the Messages flag set, cleared and reset on a new chat.
- A rendered test of the composer bar with chips, in the style of
  `ScreenViewTests`.

## Limitations

- English phrasings only. Unusual wording gets no chip; typing the command
  still works.
- Follow-up carry-over needs a looser cue in the new draft.
- A restored chat from history starts without the follow-up flag.
