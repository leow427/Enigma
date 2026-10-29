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

1. **Summary:**
2. **Files:**
3. **Decisions:** include CP0's CI result.
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
