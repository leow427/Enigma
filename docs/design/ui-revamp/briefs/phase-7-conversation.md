# Phase 7: Conversation

Read [../agent-workflow.md](../agent-workflow.md) and the spec,
[../README.md](../README.md), first. Then read the debriefs at the end of
the phase 3 to 6 briefs in this folder.

## Goal

With "Use new UI" on, everything inside a chat uses the new design:

- messages and replies;
- the character's move into the chat;
- activity and sources;
- attachments;
- every card shown in a chat.

With the flag off, nothing changes.

## What exists today

- **The message list.** `AppShellView.conversation` renders the list:
  - `LocalMessageView` for each message;
  - `SelectionRevisionCard` after /edit replies;
  - `AssistantActivityView` for live activity;
  - `ConversationScrollObserver` for scrolling.
- **`AppShellView.swift`** also holds `LocalMessageView`, `SentImagePreview`,
  `ThinkingStatusView` (with the old web-view `EnigmaCoalescenceView`),
  `SelectionRevisionCard`, and `SelectionContextCard`.
- **`AI-Spotlight/Chat/`**: `ChatMarkdownView` in `ChatMarkdown.swift`
  renders replies, and `AssistantActivityView.swift` has the activity view and
  its source rows.
- **Attachments, by folder:**
  - `Screen/ScreenControls.swift`: `ScreenAttachmentView` and
    `ScreenUploadConsentView`.
  - `Files/FileModeControls.swift`: `FileModeAttachmentView`,
    `FileChangeSummaryView`, `FileChangesReview`, and `FileRecoveryMenu`.
  - `Messages/MessagesControls.swift`: `MessagesSendApprovalCard` and
    `MessagesIssueView`.
- **`composerAccessories`** shows these above the composer.
- **Tests:** `ScreenViewTests` and others host these views. They must keep
  passing for the old UI.

## Design

The mockup is the chat in [../main-window.html](../main-window.html) (`#log`)
and the spec's "Chat" layout note.

- **User messages:** right-aligned bubbles in `userBubble`.
- **Replies:**
  - Set in serif (`EnigmaTypography.reply`) with roomy line spacing.
  - The character sits in a 30 pt slot to the left of the latest reply.
    Earlier replies show `EnigmaMark` in that slot.
  - A monospace meta line goes under each reply: `model · where it ran ·
    time`, built from what the message records.
- **Markdown:** links in `accentText`, and code in `EnigmaTypography.mono` on
  an opaque `surface` with a `border` edge. Tables and lists match.
- **Motion:** new messages and rows arrive with `EnigmaMotion.rowEnter`.
  Reduce Motion fades them in instead.
- **Activity and sources:** monospace status lines, with plain rows for
  sources. No boxes beyond a hairline.
- **Cards:**
  - Covered: selection revision, the Messages send approval, the file
    change summary and review, the screen upload consent, attachments, and
    image previews.
  - Style: an opaque `surface` with a `border` edge and the shared controls.
    Each card has at most one `accent` button, its primary action, such as
    Replace text, Send, or Allow.
  - Keep every word of consent and approval copy that carries meaning.

The mockup's copy and retry icons are placeholders. Show only actions that
exist today, and list the rest in the debrief.

## Build

1. **Views.** New files for the message list, user message, reply, markdown
   styling, activity, and each card, next to the code they present. They
   take the same models and closures as the old views.
   - If you need logic to decide which messages show the mark versus the
     character, or what the meta line says, put it in small types with
     tests.
   - Don't change `ChatMarkdown`'s parsing. Add a styling layer.
2. **The character in the chat.**
   - On the first send, the character falls from the main page slot into
     the new reply's slot (`fall(to:)`).
   - On later replies, it moves to the newest reply's slot.
   - Its state follows the request:
     - thinking while preparing or searching;
     - answering, with one `token()` per streamed update;
     - the error state when the request fails.
   - It returns to idle when the reply is done.
   - This replaces `ThinkingStatusView` and `ThinkingComposerGlow` in the new
     UI. Keep the accessible "Thinking" announcement.
3. **Flag wiring.** With the flag on, `AppShellView.conversation` and
   `composerAccessories` use the new views. Scrolling, the initial bottom
   anchor, the per-session identity, and expanding activity behave exactly as
   before.
4. **Tests.**
   - The new logic.
   - The new list renders long markdown, code, tables, images, and activity
     at the minimum and default sizes.
   - Each card's actions call the same closures as before.
   - The approval, consent, and review cards keep their failure and cancel
     paths.
   - The flag swaps the views while the app runs.
5. **Screenshots.** Paper and Ink of:
   - a conversation with markdown, code, and a table;
   - a reply streaming, with the character answering;
   - an error;
   - activity with sources;
   - each card;
   - a sent image.

   Save them to `docs/design/ui-revamp/screenshots/phase-7/`.

## Acceptance

- `scripts/verify-xcode.sh build`, `test`, and `analyze` pass.
- With the flag off, the conversation is unchanged.
- With the flag on, every chat feature behaves as before:
  - streaming, stop, and scroll;
  - the activity disclosure;
  - /edit with revise and Replace text;
  - Messages approval and send;
  - file mode review and recovery;
  - the screen consent and attachments.
- The character falls into the chat on the first send, and reflects each
  request's state.

## Debrief

**Built.** With "Use new UI" on, the chat and everything above the composer
use the new design.

- **Your messages** are right-aligned `userBubble` bubbles.
- **Replies** are set in serif. The character sits in a 30 pt slot beside the
  latest reply, and earlier replies show the outline `EnigmaMark`. Each reply
  ends with a monospace meta line: `model · where it ran · [brave search] ·
  time`.
- **Markdown styling** is a layer over `ChatMarkdown`, whose parsing is
  unchanged.
- **Activity** is a monospace line that opens to show the steps and sources.
- **Cards** are opaque and have one accent button each, with every word of
  consent and approval copy kept. This covers selection revision and context,
  the Accessibility card, screen attachment, consent, uploads-off and error,
  Messages approval and issue, file attachment, summary and review, and sent
  images.

The character's movement:

- On the first send, it falls from the main page into the reply.
- On later replies, it moves to the newest reply.
- When you open another chat, it is already in that chat's slot.
- It thinks while preparing, answers once per streamed update, shows the error
  state on failure, and goes back to idle.

Reply slots move with the content as it scrolls. A move whose slot never
appears hides the character after a grace period you can inject, which is
600 ms by default. The latest slot pins under the top edge during long
replies.

Phase 6's gaps are closed: the old glass cards are gone from the new frame,
and the thinking state shows in a placeholder reply row.

Replies now keep their model and route in a session-only `ReplyOrigin` for
the meta line. It isn't saved and is never sent to a provider. Shared
`.enigmaEdge` and `EnigmaTypography.reply(size:weight:)` replace repeated
border and font code across the phases. Screenshots are in
`screenshots/phase-7/`.

**Decisions.**

- The meta line shows clock time, because no duration is recorded.
- Messages gather at the bottom by the composer. The column is capped at the
  composer's width.
- Cards use a compact accent button. Sheets keep the full one.

**Left out**, because the app doesn't have these today:

- the copy and retry icons;
- the "thinking… 1.2s" timer;
- the top fade mask.

**Review.** There were no blockers and no should-fix findings. The reviewer
confirmed:

- data safety: saved chats decode and encode as before;
- the old UI and the old compact panel are unchanged;
- the consent and approval wording and paths are intact;
- full parity.

All seven nits were fixed:

- recovery-sheet and replaced-destination tests;
- a geometry observer only on the latest reply;
- no stray placement before a slot is measured;
- the character appears at once when you open a saved chat;
- shared edge and font helpers;
- an injectable grace period, so the tests don't depend on timing.

**Verification.**

- **Build and analyze:** both succeeded.
- **Full suite:** 795 executed, 15 skipped, 0 failed.
- **Edge refactor:** static card renders are byte-identical before and after.
- **Coordinator re-run:** conversation, main window, persistence, and
  controls tests: 74 executed, 2 skipped, 0 failed.

**Not yet checked by a person in the signed app:**

- the live fall and the sticky slot;
- Reduce Motion, Increase Contrast, and VoiceOver;
- Replace text pasting into a real app.
