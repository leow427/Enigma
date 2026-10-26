# Keep typing while a reply streams (to-do F2): implementation brief

This brief drives to-do item **F2** ("Keep typing while a reply streams") in
`to-do.md`. Read that item in full first: its **Wanted**, **Files**, **Tests**,
**Docs** and **Out of scope** sections are the requirements. This brief records
what was checked against `main` (93fd349) while planning, and the design
decisions, so the worker doesn't need to re-derive them.

## Facts checked while planning (2026-10-25)

- The composer's editability is `composerIsEnabled` (`AppShellView.swift`),
  which is false while `localChat.isBusy || screen.isBusy || files.isWorking ||
  files.isPicking`. It feeds `EnigmaComposer(isEnabled:)`, the compact panel's
  composer and `EnigmaCommandExamples(isEnabled:)`.
- `submitDraft()` bails out while busy. Every send path (`submit`,
  `submitCloud`, `submitAuto`, `submitScreen`, `submitFiles`,
  `submitMessages`) also guards `!isBusy` and silently returns.
- `ComposerSubmission.canSubmit(isBusy:)` makes `canSendDraft` false while
  busy.
- `composerText`'s getter returns "" while `pendingUserMessage != nil`, so a
  keystroke in that window is written to `screen.draft` but the field shows
  "", and the next keystroke overwrites the draft with just that character.
- `stopStreaming()` clears `activeRequest` and cancels the task, so the
  task's later `finishGeneration` returns at its `activeRequest?.id == id`
  guard: **Stop never reaches `finishGeneration`'s tail.** A failure does, with
  `error != nil`; success does, with `error == nil` and the task not cancelled.
- A failure before acceptance (`engine.prepare` throwing, search failing)
  calls `finishGeneration(error:)` without `onAccepted` having run, and the
  user message was never appended. `submitCloud` can also fail synchronously
  (`CloudContext.prepare` → `state = .failed`, no request started), and every
  submit can return early on a guard without starting anything.
- `selectSession` and `cycleRecentChat` refuse while busy, so with a queue
  they only run while it's held (or empty).
- `ShellPresentation.requestBusyChanged` sets focus to `!isBusy`.
- `ChatReturnState.hasUnsentWork` (`SpotlightPanelController.swift`) is built
  from the draft, attachments, file selection, pending selection revision and
  the Codex hand-off.

## Design decisions

1. **`MessageQueue` (new, `Enigma/Chat/MessageQueue.swift`)** is a pure
   `Equatable` value type: an ordered list of `QueuedMessage { id: UUID; text:
   String }`, `static let capacity = 5`, and `isHeld: Bool`. Operations:
   `enqueue(_:) -> Bool` (false at the cap or for blank text), `cancel(id:)`,
   `popNext() -> QueuedMessage?` (nil while held), `take(id:)` (for Send now:
   removes and returns that message), `returnToHead(_:)`, `hold()`,
   `resume()`, `clear()`, `isFull`, `isEmpty`. Cancelling the last held message
   leaves an empty queue that is not held.
2. **`LocalChatViewModel` owns the selected chat's queue** as
   `@Published private(set) var messageQueue = MessageQueue()`. It does not
   know about modes, providers or slash commands. AppShellView installs a
   sender: `var queuedMessageSender: (@MainActor (QueuedMessage) -> Void)?`.
   The sender plans and submits the text on the route selected *now*, exactly
   as `submitDraft` would for a typed draft with that text (no file selection,
   no screenshot: text only).
3. **Tracking a queued send.** The view model records the message it handed
   to the sender as `queuedInFlight` and whether its `onAccepted` ran (the
   sender wraps acceptance; expose a small view-model method the sender calls,
   or pass the message through, whichever is simpler). Then:
   - The request **succeeds** (`finishGeneration` with no error, not
     cancelled): clear `queuedInFlight`; if the queue isn't held, send the next
     one. Dispatch the next send on a fresh main-actor turn (`Task { @MainActor
     in … }`), after `finishGeneration` has reset state, so the submit's
     `!isBusy` guard passes.
   - The request **fails after acceptance**: the message is in the chat; hold
     the queue. The error shows as it does today.
   - It **fails before acceptance** (error, or the sender started no request at
     all, e.g. a guard returned or `submitCloud` failed synchronously): put
     the message back at the head of the queue and hold it.
   - **Stop** (`stopStreaming`): hold the queue. A queued message stopped
     before acceptance goes back to the head; one already accepted stays in the
     chat as sent.
   - A reply the person sent directly (not from the queue) behaves the same:
     its success drains, its failure or Stop holds.
4. **Send now** on message *m*: take *m* out of the queue, stop the running
   reply if any (`stopStreaming`, which holds), then resume the queue and send
   *m* at once. Remaining messages drain after it in order. On a held queue
   with nothing running, it's the same minus the stop.
5. **Clearing.** `newChat`, `startTemporaryChat`, `selectSession` (to a
   different chat) and `cycleRecentChat` (when it changes chat) clear the queue
   and `queuedInFlight`. ⌘N and the selection shortcut keep clearing the draft.
6. **Composer split.** `composerCanType` = not welcome/tour, not
   `screen.isBusy`, not `files.isWorking`/`files.isPicking`, and not a
   blocking model operation; a running reply does *not* block typing.
   `composerIsEnabled` stays as the "can send immediately" notion where it's
   still needed. Attach and capture stay off while busy. `/` button and slash
   completion follow `composerCanType`.
7. **Queueing a draft while a reply runs.** Return and the new Send button
   queue the draft when `localChat.activeRequest != nil` (or a queue is
   draining), the draft isn't blank, the queue isn't full, and the draft
   doesn't contain a typed `/screen` or `/snapshot` (those stay in the field;
   reuse the existing slash-command parsing to detect them). Queued text is
   stored as typed; commands resolve at send time through `ComposerIntent`,
   like a normal send. Queueing clears the field. While a held queue exists
   and nothing runs, a normal Send sends the draft directly (the queue stays
   held) — the person can Send now or cancel the held ones.
8. **Composer UI.** In `EnigmaComposer`, while responding: Stop stays where
   it is; when the field has text, a separate queue Send button (arrow.up)
   appears beside it, disabled at the cap, with accessibility label "Queue
   message" and an `enigmaTestMarker`. ⌘. still stops. The compact panel has no
   queue (out of scope); don't add the button there.
9. **Queued rows.** `EnigmaMessageList` takes `queued: [QueuedMessage]` plus
   `sendNow`/`cancel` closures, drawn after the `ForEach` over
   `transcript.rows` and before the footnote. Each looks like the user bubble
   but with a dashed hairline outline (`StrokeStyle(lineWidth: 1, dash: …)`,
   colour from the theme's hairline token), an x button to cancel, and below it
   a clock icon with "Send now". Once sent the message becomes a normal
   transcript row (solid). Keep the queue out of `ConversationTranscript`.
   B13's `sendRevision` keys on the last *user* message in
   `presentationMessages`, so queued rows don't affect it; confirm a queued
   send still scrolls to the sent message.
10. **Focus.** `requestBusyChanged` keeps focus while a reply runs (only
    non-reply busy work, if any, takes it away). Change the method signature if
    it needs to tell them apart.
11. **`composerText` fix.** Show `screen.draft` always; the
    `draftAfterAcceptance` path already clears the field on acceptance unless
    it was edited. Check `recognizedCommands` (chips hidden while
    `pendingUserMessage` is set) still makes sense — leave it hidden only if
    showing chips for the new draft would be wrong.
12. **`ChatReturnState`** gains the queue: a non-empty queue (held or not)
    counts as unsent work.
13. **Nothing queued is persisted.** The queue never touches `sessions` or
    `persistSessions`; a message is saved only once sent, by the usual path.

## Tests

As listed under the item's **Tests**. `RequestLifecycleTests` already has
fake engines/providers; set `queuedMessageSender` to a closure that calls
`chat.submit(...)` / `submitCloud(...)` to exercise the drain. Hosted UI tests
live with the existing composer tests (`ScreenViewTests` and similar); search
for `enigmaTestMarker` usage to find the pattern.

## Docs

`docs/Chat.md` sections named in the item, and `docs/design/UI-Style.md` for
the dashed outline. Add a `**Plan:**` line linking this file under F2's
heading in `to-do.md`.

## Decisions made while implementing

- The queue's Send beside Stop is an outlined icon button, not `accent`
  filled: UI-Style allows one `accent` control per view, and Stop keeps it.
- A queued message never takes a screenshot or files: `consumeSelection`
  clears a File Mode selection on every files request, so a selection present
  when a queued message sends belongs to the field's draft. A draft with a
  screenshot or files attached stays in the field rather than being queued
  without them. (Changed after review round 1.)
- A queued `/messages` for a cloud provider that hasn't had its one-time
  disclosure isn't sent and doesn't open the disclosure for a message the
  person can't see; the queue holds it at the head with a note to approve
  Messages from the field first.
- Sending from the field while the queue is held sends directly and leaves
  the queue held; only Send now resumes it.
- Dismissed recognized-command chips travel with the queued message, so a
  dismissed search doesn't come back when it sends.
- Typing is allowed during a File Mode run too (decision 6 had kept
  `files.isWorking` blocking it): Attach and capture stay off, and Stop's
  workspace revoke is unchanged.
- Focus goes to the field when a reply starts and the field stays editable,
  so the next message can be typed even after clicking Send.
