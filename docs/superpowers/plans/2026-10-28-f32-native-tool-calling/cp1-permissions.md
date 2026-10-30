# CP1: Permissions

Read [agent-workflow.md](agent-workflow.md), the spec (§2, "Privacy",
"Testing"), and [CP0's Hand-off](cp0-probe-and-flags.md#hand-off).

## Goal

Build the grant store, the permission coordinator and card, the Settings
list of Always grants, and the gate inside `MessagesTools`. Nothing uses the
gate on a live route yet (CP4 wires it); `MessagesTools` without a gate
behaves exactly as today.

## Starting point

- `MessagesCoordinator` (`Enigma/Messages/MessagesCoordinator.swift`) is the
  pattern: `@Published pendingSend`, a `CheckedContinuation<Bool, Never>`,
  `confirm(_:)` refuses when one is pending, awaits inside
  `withTaskCancellationHandler` and answers false on cancel; `answer(_:)`
  resumes. The card `MessagesSendApprovalCard` renders in
  `AppShellView` (around `if let approval = messages.pendingSend`).
- `MessagesTools` (`Enigma/Messages/MessagesTools.swift`):
  `init(database:contacts:sender:timeZone:confirmSend:)`; `list_conversations`
  adds a last-message preview; `get_messages`, `search_messages` return
  message text; `MessagesChatRecord` has `guid`, `displayName`, `handles`.
- Settings pattern: `@MainActor final class …: ObservableObject` with
  `init(defaults:)` and `didSet` writes (e.g. `WebSearchSettings`).
- `MessagesSettingsSection` (`Enigma/Messages/MessagesSettingsSection.swift`).

## Interfaces

**Produces:**

```swift
// Enigma/Chat/ToolPermissions.swift
enum ToolDestination: String, Codable, Sendable, CaseIterable {
  case thisMac, openAI, anthropic, google
  init(route: Route)              // local → thisMac; chatGPT/openAI → openAI;
                                  // claudeCode/anthropic → anthropic; gemini → google
  var displayName: String         // "this Mac", "OpenAI", "Anthropic", "Google"
}
enum ToolPermission: Sendable, Equatable {
  case readChat(chatGUID: String, name: String)
  case searchChats(query: String)
  case searchAfterMessages(query: String)
}
enum ToolPermissionAnswer: Sendable { case deny, conversation, always }
struct ToolAlwaysGrant: Codable, Hashable, Identifiable, Sendable {
  enum Kind: String, Codable, Sendable { case readChat, searchChats, searchAfterMessages }
  let kind: Kind; let chatGUID: String?; let chatName: String?; let destination: ToolDestination?
}
@MainActor final class ToolGrantStore: ObservableObject {
  static let shared: ToolGrantStore          // in-memory suite when TestHost.isActive
  static let defaultsKey = "tools.alwaysGrants"
  init(defaults: UserDefaults)
  @Published private(set) var alwaysGrants: [ToolAlwaysGrant]
  func isGranted(_ permission: ToolPermission, destination: ToolDestination, session: UUID) -> Bool
  func record(_ answer: ToolPermissionAnswer, for permission: ToolPermission,
              destination: ToolDestination, session: UUID)
  func remove(_ grant: ToolAlwaysGrant)
  func endSession(_ session: UUID)          // drops conversation grants and the message-text mark
  func markMessageText(session: UUID)
  func hasMessageText(session: UUID) -> Bool
}
// Enigma/Chat/ToolPermissionCoordinator.swift
struct ToolPermissionRequest: Sendable, Equatable, Identifiable {
  let id: UUID; let permission: ToolPermission; let destination: ToolDestination; let session: UUID
  var title: String; var detail: String     // the plan's Copy table
}
@MainActor final class ToolPermissionCoordinator: ObservableObject {
  init(store: ToolGrantStore)
  @Published private(set) var pending: ToolPermissionRequest?
  func authorize(_ permission: ToolPermission, destination: ToolDestination, session: UUID) async -> Bool
  func answer(_ answer: ToolPermissionAnswer)
}
// Enigma/Messages/MessagesAccessGate.swift
protocol MessagesAccessGate: Sendable {
  func mayRead(chatGUID: String, name: String) async -> Bool
  func maySearch(query: String) async -> Bool
  func isAllowed(chatGUID: String) async -> Bool   // no card; for previews
  func didReturnMessageText() async
}
struct CoordinatorMessagesGate: MessagesAccessGate {
  init(coordinator: ToolPermissionCoordinator, destination: ToolDestination, session: UUID)
}
// MessagesTools
init(database:contacts:sender:timeZone:confirmSend:gate: (any MessagesAccessGate)? = nil)
```

**Keying:** `readChat` by chat GUID and destination; `searchChats` by
destination (the query isn't part of the key); `searchAfterMessages` by
nothing (one grant covers every destination). Conversation grants are keyed
additionally by session.

## Tasks

### Task 1.1: Grant store

**Files:** create `Enigma/Chat/ToolPermissions.swift`; tests in new
`EnigmaTests/ToolPermissionTests.swift` using a `UserDefaults(suiteName:)`
removed in `tearDown`.

- [ ] **Write failing tests:**
  - `testDestinationForEveryProvider`: each `CloudProviderID` case and the
    local route map as the Interfaces comment says.
  - `testConversationGrantIsPerSession`: granted in session A, not in B.
  - `testAlwaysGrantPersists`: a new store on the same defaults sees it.
  - `testAlwaysIsKeyedPerDestination`: Always for `thisMac` doesn't grant
    `anthropic` for the same chat.
  - `testSearchChatsIgnoresQuery`: granted for "dinner", granted for "rent".
  - `testSearchAfterMessagesIgnoresDestination`.
  - `testDenyRecordsNothing`.
  - `testRemoveDropsAlwaysGrant`.
  - `testEndSessionClearsConversationGrantsAndMark`: grants and
    `hasMessageText` are gone; Always grants stay.
  - `testCorruptDefaultsLoadEmpty`: garbage under the key gives no grants
    and no crash.
- [ ] **Implement** and run them.

### Task 1.2: Coordinator and card

**Files:** create `Enigma/Chat/ToolPermissionCoordinator.swift` and
`Enigma/Chat/ToolPermissionCard.swift`; modify `AppShellView.swift` to render
the card next to `MessagesSendApprovalCard` when `pending` is set. Tests in
`ToolPermissionTests`.

`authorize` returns true at once when `isGranted`; otherwise it publishes
`pending`, awaits the answer inside `withTaskCancellationHandler`, records it
through the store, and returns `answer != .deny`. A request while another is
pending returns false at once. Cancellation answers `.deny`.

- [ ] **Write failing tests:**
  - `testGrantedPermissionDoesNotAsk`: `pending` stays nil.
  - `testAnswersRecordAndReturn`: deny → false and nothing stored;
    conversation → true and session grant; always → true and Always grant.
  - `testCancellationWhileCardOpenDenies`: cancel the awaiting task;
    returns false, `pending` is nil.
  - `testSecondRequestWhileOneIsOpenIsDenied`.
  - `testCardCopy`: `title`/`detail` for each permission and destination
    equal the plan's Copy table exactly.
- [ ] **Implement.** The card follows `MessagesSendApprovalCard`'s layout and
  `docs/design/UI-Style.md`; buttons in the Copy table's order, with `Always`
  last; VoiceOver labels from the same strings.
- [ ] **Add** a snapshot-style test if the send approval card has one
  (follow its test); otherwise a view test that the three buttons call
  `answer` with the right values.

### Task 1.3: The gate in `MessagesTools`

**Files:** create `Enigma/Messages/MessagesAccessGate.swift`; modify
`MessagesTools.swift`. Tests in `EnigmaTests/MessagesTests.swift`
(`MessagesToolsTests`) with the existing fake database.

With `gate == nil`, nothing changes. With a gate:

- `get_messages`: resolve the chat first; an unknown chat ID returns today's
  error without calling the gate. Then `mayRead(chatGUID:name:)` (name as
  `summary(of:)` builds it); false returns `The user declined.` with
  `success: false`. After returning text, `didReturnMessageText()`.
- `search_messages`: `maySearch(query:)` first; after returning any hit,
  `didReturnMessageText()`.
- `list_conversations`: include a chat's preview only when
  `isAllowed(chatGUID:)`; call `didReturnMessageText()` if any preview was
  included.
- `search_contacts` and `send_message`: unchanged (sending keeps
  `confirmSend`).

- [ ] **Write failing tests** (a recording fake gate):
  - `testUngatedToolsAreUnchanged`: existing tests pass, untouched.
  - `testReadAsksWithChatName`, `testDeclinedReadReturnsNoText`.
  - `testUnknownChatIDFailsWithoutAsking`.
  - `testSearchAsksWithQuery`, `testDeclinedSearchReturnsNoText`.
  - `testListHidesPreviewsOfChatsNotAllowed`.
  - `testPreviewAndSearchHitsMarkMessageText`: a shown preview, a search hit
    and a read each call `didReturnMessageText`; a list with no previews and
    a search with no hits don't.
- [ ] **Implement** `CoordinatorMessagesGate` (hops to the main actor for the
  coordinator and store) and test it end to end once with a real
  coordinator: `testCoordinatorGateRecordsMessageText`.

### Task 1.4: Settings list

**Files:** modify `MessagesSettingsSection.swift`.

- [ ] **Add** an `Always allowed` group listing `ToolGrantStore.shared.alwaysGrants`
  with the plan's row copy and a `Remove` button each; hidden when empty.
- [ ] **Test** `testSettingsRowsCopy` on the row-text function (keep the
  text in a testable static function).

## Exit criteria

- `build`, `test`, `analyze` pass; every pre-existing test passes unedited.
- No live route constructs a gate yet (`grep` the diff).

## Reviewer checklist

- No path returns message text through a gated `MessagesTools` before the
  gate says yes; unknown IDs never show a card.
- Continuations resume exactly once (answer, cancel, second request).
- Keying matches the Interfaces block; Always survives a new store; session
  data never reaches `UserDefaults`.
- No message text, names or queries in logs.

## Hand-off

*Filled in by the CP1 worker.*

1. **Summary:** Added the grant store, the permission coordinator and its
   in-chat card, the gate in `MessagesTools`, and the Settings list of Always
   grants. Nothing constructs a gate yet, so no live route asks or hides
   anything; `MessagesTools` without a gate behaves exactly as before. The
   card renders in `AppShellView` whenever `toolPermissions.pending` is set,
   which nothing does outside tests until CP4.

2. **Files:**
   - `Enigma/Chat/ToolPermissions.swift` (new): `ToolDestination`,
     `ToolPermission`, `ToolPermissionAnswer`, `ToolAlwaysGrant` (with a
     `Key` that ignores the chat name) and `ToolGrantStore`.
   - `Enigma/Chat/ToolPermissionCoordinator.swift` (new):
     `ToolPermissionRequest` (title and detail from the plan's Copy table)
     and `ToolPermissionCoordinator`.
   - `Enigma/Chat/ToolPermissionCard.swift` (new): the card.
   - `Enigma/Messages/MessagesAccessGate.swift` (new): the protocol and
     `CoordinatorMessagesGate`.
   - `Enigma/Messages/MessagesTools.swift`: `gate` (property and init
     argument, default nil); gated `get_messages`, `search_messages` and
     `list_conversations`; `declinedResult`.
   - `Enigma/Messages/MessagesSettingsSection.swift`: the `Always allowed`
     group, `rowText(for:)`, `alwaysAllowedHeading`.
   - `Enigma/LocalInference/LocalChatViewModel.swift`: owns
     `toolPermissions` (init argument, default a coordinator on
     `ToolGrantStore.shared`), so the shell can render its card.
   - `Enigma/App/AppShellView.swift`: renders `ToolPermissionCard` after
     `MessagesSendApprovalCard`.
   - `EnigmaTests/ToolPermissionTests.swift` (new): store, coordinator,
     copy, gate end to end, Settings rows.
   - `EnigmaTests/MessagesTests.swift`: `RecordingMessagesGate` and the
     gated `MessagesToolsTests` (in an extension; existing tests untouched).
   - `EnigmaTests/EnigmaConversationTests.swift`:
     `testToolPermissionCardButtonsAnswerInOrder` (clicks each button, as
     the send approval card's test does),
     `testToolPermissionInTheWindowResolvesTheToolCallAndCancellingDenies`
     (the card in the real shell), and an opt-in `card-tool-permission`
     snapshot in the existing gallery test.
   - `EnigmaTests/EnigmaMainWindowTests.swift`: the shared window `Fixture`
     gives its chat a coordinator on the fixture's own defaults suite.
   - `Enigma.xcodeproj/project.pbxproj`: the five new files.

3. **Decisions:**
   - **CP0's CI:** the run on `914387c` (Fix CI after F32 CP0) passed
     (`build-and-test`, 8m50s).
   - **`ToolDestination.init?(route:)` is failable** (the brief's interface
     is non-failable). A cloud route whose provider ID isn't a
     `CloudProviderID` answers nil, so no card can name the wrong company or
     claim "It stays on this Mac." `NativeTools.isCapable` already refuses
     such routes, so CP4 can unwrap where it builds a gate.
   - **Where the coordinator lives:** `LocalChatViewModel.toolPermissions`,
     next to `appleMessages`. The brief asked for the card in
     `AppShellView` but named no owner; this is the smallest one the shell
     can observe and CP4's `submitNative` can reach.
   - **Hidden previews** keep `id`, `from`, `date` and `has_attachment`, and
     drop `text` and `reaction` (a tapback quotes the message). The
     `list_conversations` description says so when a gate is set; without
     one it is unchanged. "Message text returned" means a shown preview with
     text or a reaction, a read that returned at least one message, or a
     search with at least one hit.
   - **Stop while a card is open** answers Don't allow, and the tool then
     returns today's cancelled result ("The request was stopped.", terminal)
     rather than "The user declined.", so the loop ends as Stop does today.
   - **A late cancel never answers a newer card:** the coordinator resolves
     by request ID, so cancelling a finished request can't close the next
     card.
   - **Always grants** are stored as a JSON array under `tools.alwaysGrants`.
     Granting a chat again under a new name replaces its row. Conversation
     grants and the message-text mark stay in memory only.
   - **`ToolGrantStore.shared`** uses a scratch suite (cleared at start)
     under `TestHost.isActive`. `defaults` is internal so a test can check
     that without touching `UserDefaults.standard`.
   - **Gated `search_messages` trims the query and refuses an empty one
     before asking** (review round 1), so a search that can't run never
     shows a card or saves a grant, and the card shows what is searched.
     Ungated search is unchanged.
   - **Card text stays on one line** (review round 1): line breaks and
     control characters in a query or chat name become spaces in the card's
     title (`ToolPermissionRequest.oneLine`), so a model-written query or
     someone else's group name can't add a fake "It stays on this Mac."
     line. The permission itself keeps the raw text.
   - **Hidden characters show as `�`** (review round 2): control and
     format characters and every default-ignorable code point (variation
     selectors, zero-width spaces, tag characters, Hangul fillers) appear as
     U+FFFD in the card's title, so gate 3's card can't hide part of a query.
     Some emoji with variation selectors look odd in a card; that is
     cosmetic.
   - **Review rounds:** two. Round 2 found one small Should fix; on the
     owner's instruction (2026-10-28) I fixed and tested it myself and
     skipped a third reviewer.
   - **Card styling:** For this conversation is the one `compactPrimary`
     button, so the lasting answer is never the default; Escape is Don't
     allow. The web-search card uses the `globe` symbol, the Messages cards
     the Messages glyph.
   - **Test-first:** for Task 1.3 and 1.4 the tests were written and seen
     failing (compile errors: no `gate`, no `alwaysAllowedHeading`) before
     the code. For Tasks 1.1 and 1.2 I wrote the code first and the tests
     straight after.

4. **Verification:**
   - `scripts/verify-xcode.sh test -only-testing:EnigmaTests/ToolPermissionTests
     -only-testing:EnigmaTests/MessagesToolsTests
     -only-testing:EnigmaTests/EnigmaConversationTests/testToolPermissionCardButtonsAnswerInOrder`:
     59 executed, 0 failed. After review round 1's fixes, with the new
     tests and the send approval window test: 64 executed, 0 failed.
   - `scripts/verify-xcode.sh build`: succeeded. `analyze`: succeeded, no
     warnings in CP1's files. Full `test`: 1373 executed, 25 skipped, 0
     failed. After review round 1: 1377 executed, 25 skipped, 1 failed, the
     known load-sensitive
     `testSendNowDuringAPendingSendKeepsItsDraftAndAttachedFilesStayWithTheField`,
     which passed alone.
   - After review round 2's fix: the checkpoint tests above, 63 executed, 0
     failed (the new hidden-character assertions failed first, on U+200B).
     Then `build`: succeeded; `analyze`: succeeded, 0 warnings; full
     `test`: 1377 executed, 25 skipped, 0 failed.
   - No live runs.
   - CI: recorded by the CP2 worker.

5. **Limitations:**
   - Nothing calls `ToolGrantStore.endSession` yet; CP4 wires it to chat
     deletion, eviction and new chats.
   - The Settings list can't show a row in the app until CP4 creates grants.
   - The card was checked by tests only, not by eye in the running app.

6. **For the next checkpoint:**
   - Build the gate with
     `CoordinatorMessagesGate(coordinator: chat.toolPermissions, destination:, session:)`;
     `ToolDestination(route:)` is optional.
   - Gate 3 (search after messages) is `coordinator.authorize(.searchAfterMessages(query:), …)`
     when `coordinator.store.hasMessageText(session:)`; the store is
     `coordinator.store`.
   - `MessagesTools.declinedResult` is the declined text; `gate` is also a
     settable property.
   - Pressing Stop resolves an open card as Don't allow through task
     cancellation; nothing else needs to dismiss it.
   - **`WebSearchTool` must search exactly what gate 3's card showed.** The
     card shows `ToolPermissionRequest.oneLine(query)`; if that differs from
     the model's query (line breaks, hidden characters), send what was shown
     or refuse the call. The CP4 brief currently sends the model's query
     unchanged.
   - **For the owner and CP4: the message-text mark doesn't survive a
     relaunch.** The mark is in memory only, as this brief says, but
     `ChatSessionStore` keeps recent chats across relaunches. A chat reopened
     from Recents after a relaunch may quote message text with no mark, so
     its web searches wouldn't ask (Privacy 2, Review Focus 5). CP4 could
     rebuild the mark from the loaded history, or persist it with the
     session. Found by review round 2; outside CP1's scope.
