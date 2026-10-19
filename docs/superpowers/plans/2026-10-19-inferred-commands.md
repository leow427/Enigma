# Inferred Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recognize `messages`, `search`, `think`, `edit` and `translate` from the wording of the typed draft, show them as dismissible chips in the composer, and run them exactly as if typed.

**Architecture:** Feature-local, deterministic matchers (regular expressions compiled once) feed one pure resolver, `ComposerIntent.resolve`. The chip views and `ComposerSubmission.plan` both call it, so the chips and Send agree. Inferred commands reuse the existing typed-command pipeline (`submissionPrompt` prefixes, `.messages(prompt:)`, `searchEnabled`).

**Tech Stack:** Swift 6, SwiftUI with AppKit, XCTest, macOS 26.

**Spec:** `docs/superpowers/specs/2026-10-19-inferred-commands-design.md`

## Global Constraints

- Only the typed draft can infer a command. Never inspect selection text, files, OCR, screenshots, earlier message text or tool results.
- Quoted (`"…"`, `“…”`), backticked and code-block text never infers. Reuse `WebSearchPolicy.questionText` for this normalization.
- `/screen` and `/snapshot` are never inferred.
- A typed command always wins. An inferred command never produces `fileConflict` or `messagesConflict`; it is dropped instead.
- Inferred `messages` keeps every existing safeguard: Full Disk Access preflight, the per-provider cloud disclosure, Auto staying local, and the send-approval card.
- User default `composer.inferCommands`, default `true`, controls `messages`, `think`, `edit` and `translate`. `search` follows `WebSearchSettings.canSearchAutomatically`.
- Settings copy: the switch is titled "Recognize commands from your wording".
- Chip accessibility label "Recognized command: <command>", hint "Turns it off for this message".
- Chip order: `messages`, `search`, `think`, `edit`, `translate`.
- `resolve` adds no model call, and resolving a draft stays well under 1 ms.
- The Xcode project does not use synchronized folders. Add every new file to `Enigma.xcodeproj/project.pbxproj` (`Enigma` or `EnigmaTests` target).
- Run tests with `scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Class>`. Before the final commit, run the full `scripts/verify-xcode.sh test`, `build` and `analyze`.
- Commit messages are imperative with no attribution lines, for example `Add the Messages intent policy`.

## Review Focus

1. **Everyday uses of "message" or "text" that aren't about Messages** ("summarize this text", "the error message says", "write a text for my slide"). These must not infer `messages`. Task 1 pins them.
2. **A dismissed search chip that comes back.** `submitAuto` calls `submitCloud` internally, and every submit path re-runs the automatic policy. A dismissed chip must stay off on every route. Task 4 pins this for Local, Cloud and Auto.
3. **The follow-up flag leaking across chats.** After a Messages turn in chat A, a new chat or chat B must not carry Messages over. Returning to A after an unrelated accepted request must not either. Task 4 pins this.
4. **Inferred `messages` alongside a screenshot or files.** It must be dropped silently, with no conflict error and no chip. Task 3 pins this.
5. **Commands inside quotes and curly apostrophes** ("what's", "didn’t she text me"). Quoted text never infers, and curly apostrophes still match. Tasks 1 and 2 pin this.

---

### Task 1: Messages intent policy

**Files:**
- Create: `Enigma/Messages/MessagesIntentPolicy.swift`
- Create: `EnigmaTests/ComposerIntentTests.swift` (class `MessagesIntentPolicyTests`)
- Modify: `Enigma.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `enum MessagesIntentPolicy { static func isRequested(_ prompt: String) -> Bool; static func isFollowUp(_ prompt: String) -> Bool }`. Both take the draft with typed slash commands already removed, and normalize with `WebSearchPolicy.questionText` internally.

- [ ] **Step 1: Write the failing tests**

```swift
final class MessagesIntentPolicyTests: XCTestCase {
  func testReadRequests() {
    for prompt in ["check what my sister texted me last", "what did Sam text me?", "did Mom message me today",
                   "check my messages from Alex", "any new texts from Jordan?", "what did Sam say in our chat",
                   "what did Sam say on iMessage", "show me the last text from Dad", "what didn’t she text me back about"] {
      XCTAssertTrue(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }
  func testSendRequests() {
    for prompt in ["text Alex that I'm running late", "send her a message saying hey", "send Sam a text saying hi",
                   "message Sam that dinner is at 7", "reply to Mom with ok", "tell Jordan on iMessage I'm here",
                   "iMessage Alex the address"] {
      XCTAssertTrue(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }
  func testNearMissesDoNotInfer() {
    for prompt in ["what does this error message mean", "write a commit message for this diff",
                   "what does this message mean", "write a message to my landlord about rent",
                   "explain how a message queue works", "send me a summary", "tell me about Denmark",
                   "send an email to Alex", "summarize this text", "write a text for my slide",
                   #"what does "text Alex" mean"#, "`message Sam` is a command"] {
      XCTAssertFalse(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }
  func testFollowUpCues() {
    for prompt in ["send her a message saying hey", "reply with sounds good", "tell him I'm on my way",
                   "text them back", "what about Alex?", "what else did she say"] {
      XCTAssertTrue(MessagesIntentPolicy.isFollowUp(prompt), prompt)
    }
    for prompt in ["what's 2 + 2", "thanks!", "explain photosynthesis"] {
      XCTAssertFalse(MessagesIntentPolicy.isFollowUp(prompt), prompt)
    }
  }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/MessagesIntentPolicyTests`
Expected: build failure, `cannot find 'MessagesIntentPolicy' in scope`.

- [ ] **Step 3: Implement `MessagesIntentPolicy`**

Use `static let` `NSRegularExpression`s, case-insensitive, on `WebSearchPolicy.questionText(prompt)`. Read: a read verb or question (`what did|did|has|check|show|read|any|last|latest`) near a messaging noun or verb (`text(ed|s)?|message(d|s)?|imessage|sms|our chat|my chat`) with a person reference (`me|from|<name>`). Send: a verb aimed at a person (`text|message|imessage|reply to|send <x> a (message|text)|tell <x> (on|by|over) (imessage|text|messages)`) that isn't `me`, `an email` or `a summary`. Exclusions: `error|commit|log|status|exit) message`, `message queue|broker|bus`, `this (text|message)`, `a (message|text) (to|for) …` without a send verb. A doc comment states that the input must be the typed draft only.

- [ ] **Step 4: Run the tests and see them pass**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/MessagesIntentPolicyTests`
Expected: all pass.

- [ ] **Step 5: Commit** — `Add the Messages intent policy`

### Task 2: Think and selection intent matchers

**Files:**
- Modify: `Enigma/Screen/ScreenAttachment.swift` (beside `ThinkCommand`)
- Modify: `Enigma/Chat/ConversationContext.swift` (beside `SelectionResponseMode`)
- Test: `EnigmaTests/ComposerIntentTests.swift` (classes `ThinkIntentTests`, `SelectionIntentPolicyTests`)

**Interfaces:**
- Produces: `extension ThinkCommand { static func isRequested(by prompt: String) -> Bool }`
- Produces: `enum SelectionIntentPolicy { static func command(for prompt: String) -> SlashCommand? }`. It returns `.translate`, `.edit` or `nil`, and translate wins. It doesn't check whether a selection is attached; the resolver does.

- [ ] **Step 1: Write the failing tests**

```swift
final class ThinkIntentTests: XCTestCase {
  func testThinkCues() {
    for p in ["think hard about this", "think carefully: which plan is cheaper?", "think deeply about it",
              "take your time and compare them", "walk me through it step by step", "reason it through"] {
      XCTAssertTrue(ThinkCommand.isRequested(by: p), p)
    }
    for p in ["I think it's broken", "what do you think of this?", #"what does "think hard" mean"#] {
      XCTAssertFalse(ThinkCommand.isRequested(by: p), p)
    }
  }
}
final class SelectionIntentPolicyTests: XCTestCase {
  func testEditAndTranslate() {
    for p in ["rewrite this", "make it shorter", "make this more formal", "make it friendlier",
              "fix the grammar", "fix the typos", "reword this", "proofread it", "tighten this up"] {
      XCTAssertEqual(SelectionIntentPolicy.command(for: p), .edit, p)
    }
    for p in ["translate this", "translate it to Spanish", "translate into Japanese"] {
      XCTAssertEqual(SelectionIntentPolicy.command(for: p), .translate, p)
    }
    for p in ["what does this mean?", "who wrote this?", "summarize it"] {
      XCTAssertNil(SelectionIntentPolicy.command(for: p), p)
    }
  }
}
```

- [ ] **Step 2: Run and see them fail** — `-only-testing:EnigmaTests/ThinkIntentTests -only-testing:EnigmaTests/SelectionIntentPolicyTests`

- [ ] **Step 3: Implement both matchers** with `static let` regular expressions on `WebSearchPolicy.questionText`.

- [ ] **Step 4: Run and see them pass** (same command)

- [ ] **Step 5: Commit** — `Recognize think, edit and translate requests`

### Task 3: `ComposerIntent` resolver

**Files:**
- Create: `Enigma/App/ComposerIntent.swift`
- Modify: `Enigma.xcodeproj/project.pbxproj`
- Test: `EnigmaTests/ComposerIntentTests.swift` (class `ComposerIntentResolveTests`)

**Interfaces:**
- Consumes: `MessagesIntentPolicy` (Task 1); `ThinkCommand.isRequested(by:)` and `SelectionIntentPolicy.command(for:)` (Task 2); `WebSearchPolicy.needsFreshInformation`; `ComposerCommands`.
- Produces:

```swift
struct ComposerIntent: Equatable, Sendable {
  struct Context: Equatable, Sendable {
    var draft: String
    var hasSelection = false
    var hasFileSelection = false
    var hasScreenshot = false
    var previousTurnUsedMessages = false
    var infersCommands = true
    var searchesAutomatically = false
    var dismissed: Set<SlashCommand> = []
  }
  let typed: ComposerCommands
  let inferred: [SlashCommand]          // chip order: messages, search, think, edit, translate
  let messages: Bool, search: Bool, think: Bool, edit: Bool, translate: Bool  // typed || inferred
  var hasPrompt: Bool                   // typed.prompt non-empty || edit || translate
  var submissionPrompt: String          // (think ? "/think " : "") + (translate ? "/translate " : edit ? "/edit " : "") + typed.prompt
  static func resolve(_ context: Context, now: Date = Date()) -> ComposerIntent
}
```

Resolution follows the spec's "Resolution and conflicts" section in order. Matchers receive `typed.prompt` (commands removed). The search candidate is `searchesAutomatically && WebSearchPolicy.needsFreshInformation(typed.prompt, now: now)`. Nothing is inferred while `typed.screen` is true.

- [ ] **Step 1: Write the failing tests**, one test per rule:
  - `"what did Sam text me"` → `inferred == [.messages]`, `messages == true`.
  - The same draft with `dismissed: [.messages]` → `inferred == []`, `messages == false`.
  - With `infersCommands: false` → no `messages`, `think`, `edit` or `translate`.
  - `"make it shorter"` gives `[.edit]` only when `hasSelection`. `"translate this"` gives `[.translate]` only with a selection, and `submissionPrompt` starts with `/translate `.
  - `"/translate make it shorter"` with a selection → `edit == false`, `inferred == []`.
  - `"think hard: what's the latest AI news"` with `searchesAutomatically` → `inferred == [.search, .think]` and `submissionPrompt` starts with `/think `.
  - `"what's the latest news Sam texted me"` with `searchesAutomatically` → `messages`, no `search`.
  - `"/search what did Sam text me"` → `search == true`, `messages == false`, `inferred == []`.
  - Files attached plus `"what did Sam text me"` → `messages == false`, `inferred == []`.
  - Screenshot attached plus `"what did Sam text me"` → `messages == false`.
  - `"/screen what did Sam text me"` → `inferred == []`.
  - `"what's on my screen"` and `"look at my screen"` → `inferred == []`, `typed.screen == false`.
  - `"send her a message saying hi"` with `previousTurnUsedMessages` → `[.messages]`. `"what about Alex?"` → `[.messages]` with the flag and `[]` without it.
  - `"/messages hi"` → `messages == true` and `inferred == []` (typed commands get no chip).
  - Performance: resolve a 2,000-character draft 1,000 times in under 1 second.

- [ ] **Step 2: Run and see them fail** — `-only-testing:EnigmaTests/ComposerIntentResolveTests`
- [ ] **Step 3: Implement `ComposerIntent.resolve`**
- [ ] **Step 4: Run and see them pass**
- [ ] **Step 5: Commit** — `Resolve typed and recognized composer commands`

### Task 4: Submission wiring, final search decision, follow-up flag

**Files:**
- Modify: `Enigma/App/ComposerSubmission.swift`
- Modify: `Enigma/App/AppShellView.swift` (`submitDraft`, `submitScreenAttachment`)
- Modify: `Enigma/LocalInference/LocalChatViewModel.swift`
- Test: `EnigmaTests/AppShellStateTests.swift` (`ComposerSubmissionTests`), the existing `LocalChatViewModel` test file for search and Messages

**Interfaces:**
- Consumes: `ComposerIntent` (Task 3).
- Produces:
  - `ComposerSubmission.plan(_ intent: ComposerIntent, hasFileSelection: Bool, hasScreenshot: Bool, canSubmit: @autoclosure () -> Bool) -> ComposerSubmission`. Keep the existing `plan(_ context: Context, canSubmit:)` as a wrapper that resolves with inference off, so existing tests keep their meaning. It uses `intent.messages`, `intent.search` and `intent.submissionPrompt` in place of `ComposerCommands` fields. Conflict cases look only at `intent.typed`.
  - `LocalChatViewModel`: `@Published private(set) var messagesFollowUpSessionID: UUID?`, `var previousTurnUsedMessages: Bool { messagesFollowUpSessionID != nil && messagesFollowUpSessionID == selectedSessionID }`. Set it to the session's ID where `submitMessages` calls `onAccepted()`. Set it to `nil` where every other submit path (`submit`, `submitCloud`, `submitAuto`, `submitFiles`, screen) calls `onAccepted()`, and in `newChat()`.
  - `shouldSearch(_:explicitlyEnabled:allowsAutomaticSearch: Bool = true)` and a matching `allowsAutomaticSearch: Bool = true` parameter on `submit`, `submitCloud` and `submitAuto`. `submitAuto`'s internal call to `submitCloud` passes `allowsAutomaticSearch: false` with its already-decided `searchEnabled`.
  - `AppShellView` builds one `ComposerIntent.Context` in a `composerIntentContext` computed property. It sets `hasSelection` from `localChat.attachedContexts.contains { $0.kind == .selectedText }`, `searchesAutomatically` from `searchSettings.canSearchAutomatically`, `infersCommands` from `@AppStorage("composer.inferCommands")` (default `true`), `previousTurnUsedMessages` from the view model, and `dismissed` from a new `@State private var dismissedInferences: Set<SlashCommand> = []` in `AppShellView`. `submitDraft` and `submitScreenAttachment` pass `allowsAutomaticSearch: false`. Dismissals clear when the draft (`screen.draft`) becomes empty, in the existing `.onChange(of: screen.draft)`.
  - `ScreenComposerCoordinator` stays on `ComposerCommands`. Captures never infer.

- [ ] **Step 1: Write the failing tests**
  - `ComposerSubmissionTests`: an inferred-messages intent gives `.messages(prompt: "what did Sam text me")`. An inferred-messages intent with a screenshot gives `.screenAttachment`, not `.messagesConflict`. An inferred-think intent gives `.chat(prompt: "/think …", searchEnabled: false)`. A dismissed-search intent gives `searchEnabled: false`. Typed `/messages /search` still gives `.messagesConflict`.
  - View model: with automatic search on and a key saved, `submit("latest AI news", searchEnabled: false, allowsAutomaticSearch: false)` doesn't search. Test the same for `submitCloud` and `submitAuto` with the stubbed routes the existing search tests use.
  - View model: the flag is set after an accepted Messages request, `previousTurnUsedMessages` is false after `newChat()` and after selecting another session, and it is cleared after an accepted ordinary request in the same session.
- [ ] **Step 2: Run and see them fail** — `-only-testing:EnigmaTests/ComposerSubmissionTests` plus the view-model test class
- [ ] **Step 3: Implement the wiring above**
- [ ] **Step 4: Run and see them pass**, then run the `MessagesTests`, `WebSearchTests` and `ScreenPipelineTests` classes for regressions
- [ ] **Step 5: Commit** — `Send recognized commands like typed ones`

### Task 5: Chips in both composers

**Files:**
- Create: `Enigma/App/ComposerIntentChips.swift`
- Modify: `Enigma/App/EnigmaComposer.swift` (after the route `Text` in `bar`)
- Modify: `Enigma/App/EnigmaCompactPanel.swift` (`EnigmaCompactComposer`, before the route chip)
- Modify: `Enigma/App/AppShellView.swift` (pass `inferred` and a dismiss action)
- Modify: `Enigma.xcodeproj/project.pbxproj`
- Test: `EnigmaTests/ScreenViewTests.swift`, or a new `ComposerIntentChipsTests` class in the same rendered-view style

**Interfaces:**
- Consumes: `ComposerIntent.inferred` (Task 3) and `AppShellView.dismissedInferences` (Task 4).
- Produces: `struct ComposerIntentChips: View { let commands: [SlashCommand]; let dismiss: (SlashCommand) -> Void }`. Each chip is a plain button: `command.rawValue` in `EnigmaTypography.mono(11)` with `accentText`, a small `xmark` symbol, and a capsule in palette tokens per `docs/design/UI-Style.md`. It has `.accessibilityLabel("Recognized command: \(command.rawValue)")`, `.accessibilityHint("Turns it off for this message")` and `.enigmaTestMarker("Recognized \(command.rawValue)")`. `EnigmaComposer` and `EnigmaCompactComposer` each take `var inferredCommands: [SlashCommand] = []` and `var dismissInferred: (SlashCommand) -> Void = { _ in }`.

- [ ] **Step 1: Write the failing tests.** Render the main composer with the draft `"what did Sam text me"` and `inferredCommands: [.messages]`, and assert that the `Recognized messages` marker exists. Render the compact composer the same way. Render with `[]` and assert no marker. Invoking the dismiss action removes `.messages` from the shell's resolved `inferred`.
- [ ] **Step 2: Run and see them fail**
- [ ] **Step 3: Implement the chips and pass them through `AppShellView`**
- [ ] **Step 4: Run and see them pass.** Run the app from Xcode once and check both composers in light and dark at normal and increased contrast. Take screenshots for the PR.
- [ ] **Step 5: Commit** — `Show recognized commands as chips in the composer`

### Task 6: Setting and docs

**Files:**
- Modify: `Enigma/App/SettingsView.swift` (`GeneralSettingsPage`: a new "Commands" section before "Messages · /messages")
- Modify: `docs/Slash-Commands.md`, `docs/Messages.md`, `docs/Web-Search.md`, `docs/Welcome-and-Settings.md`
- Test: the existing Settings test class (`EnigmaTests/*Settings*Tests.swift`)

**Interfaces:**
- Consumes: the `composer.inferCommands` key (Task 4).
- Produces: `EnigmaRow("Recognize commands from your wording", subtitle: GeneralSettingsPage.inferCommandsNote) { EnigmaSwitch(…, isOn: $infersCommands) }` with `@AppStorage("composer.inferCommands") private var infersCommands = true`. The note reads: "Turns on Messages, Think, Edit, and Translate when your wording asks for them, shown as a chip you can remove. Screen and Snapshot always need their command."

- [ ] **Step 1: Write the failing test.** The General page shows the switch, and toggling it writes `false` to an injected `UserDefaults` under `composer.inferCommands`. Follow the existing settings tests' pattern for injected defaults; if they use `.standard`, isolate the key the way they do.
- [ ] **Step 2: Run and see it fail**
- [ ] **Step 3: Add the switch and update the four docs.** Cover each item in the spec's "Docs to update" section: a "Recognized commands" section in Slash-Commands (what's inferred, chips, conflicts, the setting, the screen and snapshot exception, the English-only limitation), Messages without `/messages` and follow-ups, the search chip and dismissing it, and the new General switch. Update each doc's "How it works" and "Tests" lists with the new files and test classes.
- [ ] **Step 4: Run the full suite and checks.** `scripts/verify-xcode.sh test`, `scripts/verify-xcode.sh build` and `scripts/verify-xcode.sh analyze` all succeed.
- [ ] **Step 5: Commit** — `Add the recognized commands setting and docs`
