# Chat

Enigma's main window is a chat with a local or cloud model. Type a question in
the composer and press **Return**; the reply streams in beside the Enigma
character, and the conversation is saved to the sidebar's **Recents**.

![A chat in Paper](design/ui-revamp/screenshots/phase-10/chat-paper.png)

## Using chat

### The main window

- **Sidebar.** The Enigma mark, **New chat** (**⌘N**), **Recents**, and at the
  bottom **Help** and **Settings** (**⌘,**); Debug builds also show **Developer
  Tools**. The open chat
  has a small dot. The sidebar starts hidden unless **Show sidebar** is on in
  **Settings → General → New chats**. Hide or show it with the sidebar button or
  with **⌃⌘S**. While it's hidden, a slim bar at the top keeps
  show-sidebar, **New chat**, **Help** and **Settings** in reach.
- **Empty page.** A new chat shows the character, a greeting, the route's status
  line (for example "Fixture 8B is ready · on this Mac"), the **Auto / Local /
  Cloud** routing control, the composer, and a few slash commands as example
  lines. Clicking an example puts that command in the composer.
- **Conversation.** After the first send the composer moves to the bottom and the
  conversation fills the space above it. Your messages are right-aligned bubbles
  in the system font. Replies are set in a serif, with a monospace meta line
  underneath: the model, where it ran (**on this mac** or the cloud provider),
  **brave search** if web sources were used, and the time (date and time for
  replies from an earlier day). The character sits beside the latest reply;
  earlier replies show the outline mark instead.
- **Over the composer.** The route's status line, plus any notices and cards:
  a trimmed-context notice, attached selection, screenshot, files, a Messages
  send approval, or errors.

![The empty main page](design/ui-revamp/screenshots/phase-10/main-page-paper.png)

### The composer

The composer holds the message field ("Ask anything, or type / for commands"),
**Attach files** (**+**, also **⇧⌘A**), a **/** button that starts a command, a
**● local** or **○ cloud** indicator for where the next request runs, chips for
any commands recognized from your wording, the **Mode and model** menu
(**⌘K**), and **Send**.

- **Return** sends; **⇧Return** inserts a new line. Send is available only when
  the draft isn't empty and the selected mode has a usable model.
- While a reply runs, **Send** becomes **Stop** (also **⌘.**). The field keeps
  focus, even after you click Send, and you can keep typing, including slash
  commands and the **/** button; **Attach files** and screen capture stay off
  until the reply ends.
- **Queued messages.** Once the field has text during a reply, a second **Send**
  appears beside Stop; it and **Return** queue the message instead of sending
  it. Up to 5 messages can wait; at 5, Send and Return do nothing until one
  sends or is cancelled. Queued messages show under the reply with a dashed
  outline, an **x** that cancels them, and **Send now** with a clock under
  each. They send one at a time, in order, each when the previous reply ends,
  and become ordinary messages once sent. **Send now** stops the running reply
  and sends that message at once, ahead of the others.
  - A queued message can't be edited: cancel it and type it again.
  - Only text is queued. Slash commands resolve when the message sends, on the
    mode and model selected then, but a draft with **/screen** or
    **/snapshot**, or with a screenshot or files attached, stays in the field,
    so a capture is never taken at a moment you don't see. A queued message
    never takes a screenshot or files attached later for the field's draft. A
    draft of commands alone, with nothing to ask, isn't queued. A queued
    **/messages** for a cloud model that hasn't been approved for Messages
    holds the queue: approve Messages by sending a **/messages** request from
    the field, then choose **Send now** on it.
  - With **Recognize commands from your wording** on, a queued message's
    commands are recognized again when it sends, so a follow-up to a queued
    **/messages** request can use Messages without having shown its chip.
    Chips you dismissed before queueing stay off.
  - If a reply fails or is stopped, the queue holds: nothing more sends until
    you choose **Send now** on one of the messages, which sends it and
    resumes the rest. A queued message that fails before it reaches the chat
    (for example while being prepared) goes back to the front of the held
    queue. Sending from the field while the queue is held sends that message
    directly and leaves the queue held.
  - The queue lives in memory only and is never saved. **⌘N**, the selection
    shortcut and opening another chat erase it; a held queue keeps the chat
    open when you return after 5 minutes, like a draft.
  - The compact panel has no queue: its question moves to the window as soon
    as its request starts.
- Slash commands such as **/search**, **/think**, **/screen** and **/snapshot**
  apply to one message. See [Slash-Commands.md](Slash-Commands.md).
- Choosing a mode or model while a request runs applies to the next request; the
  menu's mode section reads **Next request**.

Other shortcuts in the window: **⌃Tab** opens the next recent chat, and **Esc**
closes an open menu or, with none open, hides the window.

### Streaming, scrolling and thinking

- Your message appears as soon as you send. The draft stays recoverable until the
  request is accepted: if preparation fails, for example because the message is
  too large for the model, the error appears in the status line and your draft is
  still in the composer. The field shows blank meanwhile; anything you type
  there starts a new draft, with its own recognized commands, and stays once
  the message is accepted. If that
  send then fails, what you typed stays and the sent text is gone; typing
  exactly the sent text again shows blank, as the sent draft does.
- Queued messages sit under the running reply, after the chat, and a new one
  keeps a reader at the bottom following. When one sends, the chat brings it
  to the bottom as for any sent message. A chat whose only question was
  stopped stays open while it has queued messages, so they stay in view.
- Before the first words arrive, the reply row shows the request's status line
  (see below) and the character thinks. Once text arrives it streams into the
  reply and the character answers. Model reasoning is never shown, only the
  answer.
- **Stop** keeps whatever text has already arrived.
- Replies render Markdown: headings, lists, emphasis, inline and fenced code,
  links, block quotes and tables. Code and tables scroll sideways when they're
  wide. Reply and message text can be selected and copied.
- **Copy buttons.** Each code block has a header with its language on the left
  and a **Copy code** icon on the right that turns into a check mark for a
  moment. In a terminal block (`bash`, `sh`, `zsh`, `shell` or `console`) where
  some lines start with a `$ ` or `% ` prompt, Copy keeps only those commands,
  without the prompt, and the lines their trailing `\` continues; the rest is
  output and is left out. Only prompt lines and their `\` continuations are
  kept, so a here-document's body (`$ cat <<EOF`, then its lines) is dropped
  with the output. Without a prompt line, Copy writes the block as shown, and
  `# ` is never a prompt because it is also a comment.
  A finished reply has a **Copy reply** icon at the right of its meta line. It
  rests dimmed and brightens when you point at the reply; it stays clickable
  and visible to VoiceOver and Tab (like any button, Tab reaches it with
  Keyboard navigation on). It writes the reply as plain text, without
  Markdown marks, and as rich text that pastes cleanly into Mail or Pages.
  Plain text keeps list markers, writes block quotes as plain paragraphs and
  writes tables as tab-separated rows, empty cells included. Rich text has
  fonts, paragraph breaks, list markers, links and monospace code (Menlo) but
  no colours, so Ink's light text never pastes invisibly onto a white page.
  Copy reply copies the reply's own text only: after `/edit`, the revised
  text in the revision card under it isn't included, and a reply with only
  whitespace has no Copy reply icon.
- The chat opens at its end and follows new text while you're at the bottom.
  Sending a message always brings it and its reply to the bottom of the view,
  even if you had scrolled up, and the chat follows the reply again; a reply
  taller than the window scrolls the message off the top as the chat follows
  the end. Scroll up and it stops following, so you can read earlier messages
  while a reply streams; scroll back to the bottom and it follows again.

**/think** asks for a more careful answer for that one message. It adds checking
guidance to the request and gives the model more room: local models reserve
2,048 output tokens instead of 512, and models that support it get a thinking
budget or a higher reasoning effort.

### Activity and sources

Each reply has a monospace status line that opens into its activity. While a
request runs it shows the current step, such as **Analyzing query…**,
**Searching…**, **Reading sources (3)…**, **Thinking…** or **Generating
response…**. When it ends it reads **Activity**, **Stopped** or **Request
failed**, with the source count if web search was used.

Click it to see the steps and, for searched replies, the **web sources**: each
row shows the page title, the site, whether its excerpt was **Included in
context**, and the address, and opens the page in your browser. The list scrolls
when it's long. Only excerpts that fit in the model's context are listed; a
listed source means its excerpt was sent, not that the full page was read.

![Activity with its sources open](design/ui-revamp/screenshots/phase-7/activity-sources-paper.png)

### Attachments in the chat

- **Files and folders** attached with **+** appear by name above the message they
  were sent with. Sending moves them into that message and clears the composer's
  attachment; the next message has no file access unless you attach again. See
  [File-Mode.md](File-Mode.md).
- **Screenshots** from **/screen** or **/snapshot** appear as a small preview above
  the message. See [Screen-Skill.md](Screen-Skill.md).
- **Selected text** from another app appears as a card over the composer and goes
  with the first message. See [Selection-Context.md](Selection-Context.md).

![A sent screenshot](design/ui-revamp/screenshots/phase-7/sent-image-paper.png)

### Chat history

- **Recents** lists your chats, newest activity first. A chat is titled with the
  first 48 characters of its first message ("New Chat" until then).
- Enigma keeps the **10 most recently active chats**. Older chats are dropped
  for good. A chat with no messages is never saved or counted.
- **New chats.** Launch and **New chat** both open the empty chat page with no
  chat selected in Recents. A chat with no messages, as when you've only
  attached files, exists in memory only: it isn't written, listed in Recents
  or counted toward the ten, and leaving it (a new chat, another chat,
  cycling, or the selection shortcut) removes it. Its first message saves it,
  at the top of Recents. The one exception to the listing: a selection chat
  that just moved to the window shows in Recents while its first question is
  on its way, though it's written only once that question lands.
- **Coming back.** Summoning Enigma after more than **5 minutes** away opens a
  new chat; within 5 minutes it comes back to the chat you left. Away means
  hidden (Escape, the show/hide shortcut, or the menu bar's **Privacy Hide**)
  and not used: a request that ended while the window was hidden, finished or
  failed, counts as use, and the 5 minutes run from then. A window left open
  behind other apps is not away, and keeps its chat however long it stays
  there. You always come back to the same
  chat when there's nothing to leave (no chat, or one with no messages), when
  something is unsent (text, a screenshot or files in the composer, queued
  messages, a selection revision not yet applied or dismissed, or a File Mode
  edit waiting on **Use Codex**), or while the chat is busy: a reply, file
  work, or a model install, delete or performance check holds it. A model
  download alone doesn't.
- You can't switch chats while a request is running; **New chat** stops it
  first. Opening another chat erases any held queued messages.
- **Temporary chats.** A chat started from selected text in the compact panel is
  temporary: it's marked **temporary · not saved** and nothing of it is written
  to disk. Sending its first question, or ⌘O, moves it to the main window and
  lists it at the top of Recents, written once its first question lands, unless
  **Keep selection chats private** is on in **Settings → Selection**. A private chat stays temporary, stays out of
  Recents, and is gone when you start another chat.

## Privacy

Chats are stored on this Mac in `~/Library/Application Support/AI Spotlight/chats.json`.
Each chat saves its title, timestamps, and messages: text, the web sources a
reply used, and the names (not contents) of files and folders sent with a
message. A chat also remembers files attached but not yet sent, so they're still
attached when you come back to it.

These are never saved: screenshot pixels, selected text from other apps, request
activity, the **/think** flag, and the model and route shown in the meta line.
After a relaunch, older replies show only what was saved, for example a meta line
with just the time.

Where a message is sent depends on the mode: **Local** stays on this Mac, **Cloud**
sends the conversation context to the chosen provider, and **Auto** decides per
request. See [Local-Model-Selection.md](Local-Model-Selection.md) and
[Cloud-Model-Selection.md](Cloud-Model-Selection.md).

## How it works

### Request lifecycle

`LocalChatViewModel` (`Enigma/LocalInference/LocalChatViewModel.swift`) owns the
sessions, the selected chat, and the running request for every route. Despite its
name it also drives cloud, Auto, Screen, File Mode and Messages requests.

- `AppShellView` (`Enigma/App/AppShellView.swift`) turns a Send into a
  `ComposerSubmission` (`Enigma/App/ComposerSubmission.swift`): plain chat,
  files, Messages, screen capture, or a conflict message.
- `beginGeneration` creates an `ActiveRequest` and a fresh `AssistantActivity`.
  Every later event checks that its request still owns the generation, so late
  tokens or errors from a stopped or replaced request are ignored.
- For local and searched requests, the user message is shown at once as
  `pendingUserMessage`. It's written to the session only after preparation
  succeeds; then `onAccepted` clears the draft. The composer shows the field
  blank while that send's pending bubble is visible and the draft is still the
  one sent (`sentDraft`, keyed by the pending message's id); a keystroke
  replaces it, and `draftAfterAcceptance` keeps it. Send and Return read that
  visible draft, so a second Return never queues the message already sent.
- `LocalChatViewModel.messageQueue` holds the open chat's queued messages, a
  `MessageQueue` (`Enigma/Chat/MessageQueue.swift`): order, the cap of 5, and
  whether it's held. AppShellView installs `queuedMessageSender`, which plans
  a queued message like a typed draft with no screenshot or files on the
  current route. The view model remembers the message in flight and whether
  its `onAccepted` ran. It drains the next message on a fresh turn whenever
  something that held the chat ends (`finishGeneration`, a model operation,
  a selection replacement); AppShellView also drains when `isBusy` ends, for
  the rest, such as the file picker. A failed
  `finishGeneration`, `stopStreaming()`, or a send that starts no request holds
  the queue, returning an unaccepted message to its head. `newChat`,
  `startTemporaryChat`, and switching chats clear it. Nothing in it reaches
  `sessions` or the session writer.
- Fragments append to the assistant message; `stopStreaming()` revokes ownership,
  cancels the task, and flushes history.

### Presentation

- `ConversationTranscript` (`Enigma/Chat/EnigmaConversationLogic.swift`) builds
  the rows, decides which reply holds the character's slot, and stands in a reply
  row for a request that's still preparing. `ReplyMetaLine` formats the meta line
  from the reply's session-only `ReplyOrigin`.
- `EnigmaMessageList` (`Enigma/Chat/EnigmaMessageList.swift`) lays out the rows
  and is reused by the compact panel. It uses a plain `VStack` so the chat's
  height is exact: a lazy stack estimates rows it hasn't drawn, which can leave
  empty space below the messages for following to scroll into. Its
  `ConversationScrollObserver` watches the native scroll view: it follows only
  while within 2 pt of the bottom, or once the list's send revision (the id of
  the latest message you sent) changes to a message it hasn't shown, stops on
  live scrolling, wheel or key navigation, coalesces scroll corrections for
  30 ms, and treats layout changes (such as the waiting row being replaced) as
  layout, not navigation. The list
  gets a new identity per chat, so each opens at its end.
- `ChatMarkdownView` (`Enigma/Chat/ChatMarkdownView.swift`) renders Foundation's
  Markdown parse as native blocks. `ChatResponseNormalizer`
  (`Enigma/Chat/ChatMarkdown.swift`) repairs clearly escaped formatting and odd
  whitespace for display only, leaving code, paths and URLs alone; stored text is
  unchanged. `ChatResponseStyle` (`Enigma/Chat/ChatContext.swift`) asks every
  provider for concise, standard Markdown. While a reply streams,
  `ChatMarkdownStream` keeps the reply parsed up to the last point where a new
  top-level block must start (an empty line outside code, before an unindented
  line that can't continue a list) and parses only the rest on each update, so
  a long reply doesn't get slower to stream. Its blocks are the same as parsing
  the whole reply; link reference definitions and HTML blocks that span empty
  lines fall back to parsing everything.
- `ChatCopy` (`Enigma/Chat/ChatCopy.swift`) decides what the copy buttons
  write: `copyableCode(_:language:)` for the terminal rule, and
  `plainText(_:)` and `richText(_:)` for a reply, both built from the parsed
  `ChatMarkdownBlock`s so they match what is shown. `ChatCopyButton` is the
  icon button; it writes to the `enigmaPasteboard` environment value (the
  general pasteboard unless a test sets another). A reply's button rests
  dimmed and brightens on hover, rather than being hidden, because a view at
  zero opacity can't be clicked and leaves the accessibility tree.
- `EnigmaMainColumn` and `EnigmaMainPageHeader` (`Enigma/App/EnigmaMainPage.swift`)
  switch between the empty page and the docked conversation. `EnigmaComposer`
  (`Enigma/App/EnigmaComposer.swift`), `EnigmaSidebar`
  (`Enigma/App/EnigmaSidebar.swift`) and `ChatHistoryList`
  (`Enigma/App/ChatHistoryList.swift`) draw the rest. `ShellPresentation`
  (`Enigma/App/ShellPresentation.swift`) holds sidebar visibility, the routing
  mode and which activities are expanded. The visual rules are in
  [design/UI-Style.md](design/UI-Style.md).

### Activity

`AssistantActivityEvent` (`Enigma/Chat/AssistantActivity.swift`) carries phase,
sources-discovered and sources-selected updates from search, local orchestration
and cloud adapters (`ChatEvent.activity`). `AssistantActivity` reduces them into
the snapshot that `AssistantActivityView` (`Enigma/Chat/AssistantActivityView.swift`)
draws, independent of provider. Only safe http(s) links are listed, each URL once.
Once sources are selected, only those appear. Activity is session-only; a saved
reply's `searchSources` are shown through the same view without a step timeline.

### History

`ChatSession` and `ChatMessage` are in `Enigma/Chat/ChatDomain.swift`.
`ChatMessage` encodes only `id`, `role`, `content`, `searchSources`, `createdAt`
and `attachments`; everything else is session-only. `ChatSessionStore`
(`Enigma/Chat/ChatSessionStore.swift`) loads and atomically writes `chats.json`,
sorted by last activity and capped at `maximumRetainedSessions` (10).

`ChatSessionWriter` keeps saves off the main thread: one write at a time on a
utility queue, and one replaceable pending snapshot so an older save can never
overwrite a newer one. Streamed fragments are coalesced into a save every 500 ms.
A chat's first message, later accepted messages, and attachment changes on a
chat with messages save right away; Stop, completion, failure and the app
becoming inactive flush pending changes. A temporary chat is filtered out of
every snapshot.

`LocalChatViewModel` starts with no selected chat; `ensureSelectedSession()`
creates one, at the top, when sending or a file attachment needs it, without
writing it. `isUnsaved` covers every chat with no messages as well as the
temporary chat, so such a chat stays out of the saved file and of retention, and
`historySessions` leaves it out of Recents, apart from the selection's chat
that just moved to the window. Empty chats in the file from older versions are
dropped at load. `newChat()` stops any reply, discards a temporary chat, and
returns to no selected chat. Leaving a chat with no messages, through
`newChat()`, `selectSession`, `cycleRecentChat` or `startTemporaryChat`, removes
it (`leaveEmptyChat`). `lastRequestActivityAt` records in memory when a request
last started, streamed or ended, failed or not, without moving its chat.

The return rule is `ChatReturnPolicy` in
`Enigma/App/SpotlightPanelController.swift`, given plain values: when the panel
was hidden, the time, and a `ChatReturnState` (the later of the open chat's
last activity and `lastRequestActivityAt`, whether anything is unsent, and
`isBusy`), which the
controller reads through an injected closure from the shared chat and the
window's own `ScreenComposerCoordinator`. `SpotlightPanelController.hide()`
records when the panel was hidden (keeping the first time if it's hidden
again); every way the panel is shown clears it. `show()` asks the policy before
ordering the panel front. A new chat goes out as `.newChatRequested`, the same
path as **⌘N**, so the main window resets and a compact selection panel returns
to its normal frame; the content is laid out before the panel is ordered front.
Screen capture and a
running text replacement order the panel out without `hide()`, so they don't
count as away; an automatic paste that leaves the window hidden ends with
`hide()`, as Escape does. A selection summon starts its own temporary chat as
before, and the rule applies again once that panel is hidden.

### Context budgets

The saved chat is always the full transcript. Each request sends a trimmed copy,
built by `ChatContextPreparer` (`Enigma/Chat/ChatContext.swift`):

- The current message is always included. If it can't fit on its own, the request
  is rejected before anything is saved and the draft is kept.
- Earlier history is added as **complete user/assistant pairs**, newest first,
  until the next pair would not fit. Unanswered messages and empty replies are
  skipped; a partial reply that was stopped still counts.
- When anything is left out, a notice over the composer says how many earlier
  messages were omitted and that saved history is unchanged.
- Attached selection or file context is expanded into the request copy only
  (`ConversationContextPrompt` in `Enigma/Chat/ConversationContext.swift`).

A `ContextBudget` gives the input allowance as the smaller of an input cap and
`context window − output reserve − protocol reserve`.

**Local** (`Enigma/LocalInference/`):

- The context window comes from the model's vision configuration, then its
  catalog recommendation, then a 4,096-token fallback.
- The output reserve is 512 tokens, or 2,048 with **/think**.
- Text-only models run in the embedded engine (`LlamaCPPModelEngine.swift` and
  `Packages/LlamaBridge`). Tokens are counted exactly with the model's chat
  template, the context is capped at the model's training context, and one spare
  token is reserved. A model without a usable chat template is refused. Each
  completion clears the KV cache and replays only the prepared conversation.
- Vision-capable models run in a local llama-server (`LlamaServerVisionEngine.swift`,
  `LocalMultimodalClient.swift`) with a 256-token protocol reserve and 4,096 extra
  tokens for an image. Tokens are counted with the server's `apply-template` and
  `tokenize` endpoints, using the same system message and thinking settings as
  generation. If those endpoints aren't available, it falls back to a byte
  estimate (UTF-8 bytes plus 32 per message) until the runtime reloads. Context
  shifting and prompt caching are off.

**Cloud** (`ModelContextPolicy.cloud` and `CloudContext`): input is counted as one
token per UTF-8 byte of the serialized messages, which deliberately overestimates,
plus 4,096 tokens for an image. No tokenizer or network call is used. Every cloud
client checks the budget again before sending.

| Provider | Context window | Output reserve | Protocol reserve | Input cap |
|---|---:|---:|---:|---:|
| OpenAI, Anthropic, Gemini | Reviewed model's published limit; 8,192 otherwise | 4,096 (lower if the model's maximum is lower), sent as the max-output parameter | 512 | 32,768 |
| ChatGPT via Codex | 1,050,000 for the reviewed GPT-5.6 models; 32,768 otherwise | 128,000; 16,384 otherwise | 8,192 | 32,768 |
| Claude via Claude Code | 200,000 for its listed aliases; 65,536 otherwise | 32,000; 8,192 otherwise | 16,384 | 32,768 |

Per-model limits and how models are reviewed are in
[Cloud-Model-Selection.md](Cloud-Model-Selection.md). These are application
policy; they don't certify a provider's real limits or your account's access.

Web search evidence is fitted into the same budget: it takes up to half of what's
left after the current question, and recent history is added only after the
evidence fits. See [Web-Search.md](Web-Search.md).

## Limitations

- History is best effort. There are no backups or retries, a failed save shows no
  warning, and a crash or forced quit can lose the last moments of a reply. If
  `chats.json` can't be read, the app starts with an empty history.
- Only the 10 most recently active chats are kept. Chats can't be renamed,
  deleted individually, or searched.
- Queued messages can't be edited, can't carry attachments or captures, and
  aren't available in the compact panel. A held queue stays held after a
  message sent directly from the field succeeds; choose **Send now** to resume
  it.
- A queued message that can't start when its turn comes, for example because
  the selected mode has no usable model, holds the queue with no message of
  its own; the route status line says what's missing.
- Cloud history trimming uses a conservative byte count, so it can keep less
  history than the provider would actually accept. Unreviewed or manually entered
  models get small default windows.
- Every request's input is capped at 32,768 tokens for cloud models, however large
  the model's window.
- Screenshots and request activity aren't saved, so they're gone after a relaunch.
- The chat lays out every message on each update while a reply streams, so a
  very long chat costs more per update (about 2 ms at 20 messages, 13 ms at 100
  and 70 ms at 400). Enigma's chats are meant to be short.

## Tests

- `EnigmaTests/ChatContextTests.swift`: budgets, complete-turn trimming, cloud
  byte counting, the native and server tokenizer paths, and (`ChatMarkdownTests`)
  Markdown normalization and parsing, including streamed parsing matching a
  whole-reply parse at every prefix.
- `EnigmaTests/ChatCopyTests.swift`: the terminal prompt rule and its edge
  cases, a reply's plain and rich text (lists, code inside list items, empty
  table cells), RTF fonts, the pasteboard write, the hosted Copy code button
  with its check mark, and the hosted Copy reply button (clickable while dimmed,
  absent while the reply streams or has no text).
- `EnigmaTests/ChatPersistenceTests.swift`: retention, archive loading, excluded
  fields, and `ChatSessionWriter` coalescing and write ordering.
- `EnigmaTests/RequestLifecycleTests.swift`: request ownership, Stop,
  replacement, draft preservation, partial output, and saves during streaming;
  the message queue draining in order, holding on failure and Stop, returning
  an unaccepted message to its head, Send now, clearing on a new or other chat,
  never being saved, and counting as unsent work.
- `EnigmaTests/MessageQueueTests.swift`: the queue's order, cap, hold, resume,
  Send now, cancel and clear, and which drafts can be queued.
- `EnigmaTests/EnigmaConversationTests.swift`: transcript rows, the character's
  slot, meta lines, list layout and scrolling (including the second and third
  message staying in view, with Reduce Motion on and off), sent images and
  activity.
- `EnigmaTests/ScreenViewTests.swift`: the scroll observer while streaming and
  while reading, typing after Stop with a blocked save, and the composer draft
  and screenshot in `ChatReturnState`.
- `EnigmaTests/AppShellStateTests.swift`: `ShellPresentation` (including focus
  staying in the field during a reply),
  `ComposerSubmission`, `ChatHistoryList`, and (`ChatReturnTests`) the
  5-minute return rule and the panel controller that applies it.
- `EnigmaTests/EnigmaMainWindowTests.swift`: the main page, composer and sidebar,
  including typing during a reply, text typed just after Send, queueing with
  Return and the Send beside Stop, `/screen` staying in the field, and the
  queued rows' Send now and x.
- `EnigmaTests/WebSearchTests.swift`: activity events, source selection and
  evidence packing.
- `EnigmaTests/LocalInferenceTests.swift`: streaming partial Markdown, failures
  and Stop on the local route, launch and New chat opening no chat, empty chats
  never saved or listed, and request activity counting as use.
- `EnigmaTests/FileModeUITests.swift`: files on a chat with no messages held in
  memory and removed when you leave it.
- `EnigmaTests/EnigmaCompactPanelTests.swift`: temporary and private selection
  chats, and the 5-minute return through the hosted window.
- `EnigmaTests/SelectionContextTests.swift`: selection revisions, including
  which count as unsent work in `ChatReturnState`.
