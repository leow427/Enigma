# Selection Context

Highlight text in any app, tap **Option** twice, and Enigma opens a compact panel
next to it with that text attached to a new temporary chat. Ask about the text,
translate it, or use **/edit** to get a revision that Enigma can paste back over
your selection.

![The compact panel with selected text attached](design/ui-revamp/screenshots/phase-10/compact-panel-paper.png)

## Using it

### Opening the panel

1. Select text in another app.
2. Tap **Option** twice, on its own (**⌥ twice**). The backup shortcut is
   **⇧⌥Space**.

The panel opens beside the selection, on the side that doesn't cover it and
closest to the pointer. It starts in the mode set under **Start mode** in
**Settings → General → New chats**. Each invocation starts a fresh temporary chat.

The shortcut settings are in **Help** (in the main window's sidebar, or the **?**
button when the sidebar is hidden), under **Anywhere on your Mac**:

- **Double-tap shortcut** turns the double tap on or off.
- **Selection shortcut key** chooses **Option ⌥**, **Command ⌘** or **Shift ⇧**.
- **Double-tap interval** chooses **Fast**, **Normal** or **Relaxed**.

Each tap must be a short press of that key alone; holding it, adding another
modifier, typing or clicking cancels the double tap. The double tap is ignored
while macOS Secure Event Input is on (for example, in a password field).

Separately, pressing **Option** and **Control** together and releasing them
(**⌥⌃**) shows or hides the Enigma panel without capturing anything. Using them
with another key, modifier or click does nothing.

### What the panel shows

From top to bottom:

- **The selection line**, `› selected "…"`, with a preview of the text. Beside it
  are a status button, **×** to remove the selection, and the
  **Open in window** button. With nothing captured it reads `› no text selected`.
- **The input row**: the Enigma character, the message field (placeholder
  "Ask about the selection"), **+** to attach files (see [File Mode](File-Mode.md)),
  a route chip such as `auto · local` or `cloud · <model>` that opens the mode and
  model menu, and **↵** to send (**stop** while a reply is running).
- **The hint row**: `/ commands` (or `⌘. stop` while responding), `⌘O open in window`,
  `esc close`, and on the right `temporary · not saved`.

The status button opens a details area under the input with the selected-text
card, notices, and any permission or routing cards. It shows a warning icon, and
the character shows its problem state, when Accessibility is missing or the
selection couldn't be read. Details open on their own when a request or capture
fails. When the panel sits low on the screen, the command list and the mode menu
open above the input.

Sending the first question grows the panel downward into a conversation: the
input stays where it is and the answer appears under it. Follow-up questions stay
in the same panel. With **Reduce Motion** on, it grows without animating.

![The panel grown into its answer, with the selection line reading "for /edit"](design/ui-revamp/screenshots/phase-10/compact-panel-answer-paper.png)

**Escape** closes, in order, the command list, an open menu, the details, and then
the panel. Hiding the panel keeps its chat until you start another one.

### Moving the panel

Drag the panel by any empty part of it, such as the padding around the input or
the middle of the hint row. It stays on the visible part of the screen under the
pointer, below the menu bar. Once moved, it grows and shrinks from where you put
it. The next invocation places it beside the new selection again. This drag
doesn't move the panel between Spaces or offer window tiling.

### Asking about the selection

The selection goes with your **first message only**. After a reply arrives, the
line changes to `› for /edit "…"` in a quieter color, the placeholder becomes
"Ask anything", and new questions are ordinary turns: the model can still refer
back to the selection in the conversation, but it isn't attached again. If the
first reply fails, or is stopped before any text arrives, the next message carries
the selection again.

Highlighting text never authorizes an edit. A plain question gets a read-only
answer, and asking for a rewrite without **/edit** gets a hint to use **/edit**.
With **Recognize commands from your wording** on (**Settings → General**), a
rewrite request such as "make this more formal" turns on **/edit** for you,
shown as a chip you can remove before sending. See
[Slash commands](Slash-Commands.md#recognized-commands).

**Removing** the selection (the **×** on the line or the selected-text card) takes
it, its place in earlier turns and any edited draft out of every later request, and
turns off **Replace text** for this chat.

### Editing with /edit

`/edit make this more formal` asks for one revised version. The reply briefly
describes the change, then shows a **Revised text** card:

- **Edit** turns the card into an editable draft; **Done** returns to the preview.
- **Replace text** pastes the draft into the source app.

**/edit** works on any turn and always sends the selection, plus the latest draft
if there is one, so follow-ups like `/edit shorter` refine the last version,
including your own changes. Other follow-ups see a draft only if you changed it by
hand. Each reply keeps its own draft while the chat is open. A question or an
unclear request under **/edit** can still get an ordinary answer or a clarifying
question instead of a card.

If an **/edit** reply arrives without a usable revision, Enigma makes one extra
request to the same model to prepare the card. If that fails, a notice asks you
to try again; arbitrary reply text is never pasted.

### Translating with /translate

`/translate` (or `/translate this`) translates to English;
`/translate to Spanish` picks the target. The answer is ordinary read-only text,
with no card. On a later turn, a `/translate` with no text of its own sends the
selection again, while `/translate` followed by your own text translates that text. If
**/edit** and **/translate** appear together, translation wins and stays
read-only. Asking "translate this" in plain words gets the same defaults.

### Replacing text

**Replace text** pastes into whatever is currently selected (or at the insertion
point) in the app the text came from, so moving the selection there first is
fine. The panel steps aside, Enigma activates that app, sends one **⌘V** to it,
then restores your clipboard and comes back. The card then shows
**Replacement sent** and a notice names the app.

"Sent" means the paste was dispatched; Enigma can't confirm the other app accepted
it. A sent replacement is never retried. To replace again, select the text and
invoke Enigma again.

**Settings → Selection → Automatically replace selected text** (off by default)
skips the card: a completed **/edit** revision is pasted straight away. It applies
only to **/edit** requests that start while it's on. It never applies to ordinary
answers, translations, failed, stopped or incomplete replies, or a reply whose
selection was removed. Turning it off cancels any pending automatic paste and
shows the card instead.

### Opening the chat in the main window

Press **⌘O** while the panel is focused, or click the
**Open in window** button, at any point, even before the first answer. The chat
moves into the main window at its normal size, with the sidebar as
**Settings → General → Show sidebar** sets it, and keeps the selection for **/edit**
and **Replace text**.

What happens to the chat depends on
**Settings → Selection → Keep selection chats private** (off by default):

- **Off**: the chat is saved like any other. It goes to the top of Recents,
  titled from your first question, and a line under the messages says
  "Saved to history · Enigma keeps your last 10 chats" until your next message.
  The button's tooltip reads "Open in window · saves to history".
- **On**: the chat stays temporary in the window. It isn't saved and doesn't
  appear in Recents. A line says "Private chat · not saved to history" until your
  next message, and `temporary · not saved` stays over the composer. The tooltip
  reads "Open in window · stays private".

The setting is read when you open a chat in the window; changing it later doesn't
save or delete a chat that's already open.


## Privacy and permissions

### Accessibility

Reading the selection and pasting a replacement both need macOS **Accessibility**
permission. Accessibility also lets **⌥⌃** work while another app is active. The
backup shortcut **⇧⌥Space** opens the panel without it, but no text is captured.

Without permission the panel still opens a temporary chat, explains what's
missing, and offers **Open Accessibility Settings…**. That button asks macOS for
access and opens **Privacy & Security → Accessibility** directly, in case macOS
doesn't show its prompt again. Enable **Enigma** there. The permission's status,
with a button that opens the same pane, is also in **Settings → Selection**,
**Settings → General → Permissions**, the welcome setup, and **Help**. Enigma checks again whenever you switch apps or show the
panel, so no restart is needed. If an older copy of Enigma is listed, remove it
and add the app you're running.

### What is read, and when

- The shortcut monitor looks only at modifier keys and event types; it doesn't
  record what you type.
- Text is read only when you invoke the shortcut, and replacement happens only
  when you ask for it. There is no background selection monitoring.
- While Enigma has Accessibility permission, it asks every app that comes to the
  front to turn on its full accessibility support (`AXManualAccessibility`),
  including apps you never capture from. It does the same for the frontmost app
  when Enigma starts and on the first tap of the double-tap shortcut. After an app
  launches or comes to the front, it asks again about 1 s, 3 s and 8 s later while
  that app is still in front, because a freshly launched Electron app ignores the
  request until it has finished starting. Chromium and Electron apps such as Slack and Discord build their
  accessibility tree only when asked and take about 2 s to do it, so this keeps the
  first capture there from waiting. Enigma reads nothing at that point: no focused
  element, no text. Electron warns that rendering the accessibility tree can
  noticeably affect an app's performance, so those apps may use more CPU and
  memory while it is on. VS Code and the editors built on it are never asked this
  way: they take it as a screen reader, switch to screen-reader rendering and show
  a lasting prompt. Enigma recognizes them by bundle ID (VS Code, VS Code Insiders,
  VSCodium, Cursor, Windsurf) or by VS Code's `product.json` inside the app's
  bundle (it checks that the file exists and reads nothing from it), and leaves
  alone any app whose bundle it can't identify. They are asked only when you
  actually invoke Enigma there, as capture always does.
- Enigma writes one diagnostic line per capture to the system log, with timings
  and fixed labels only: no text, app name or bundle ID (see
  [How it works](#how-it-works)).
- Password fields, secure text fields, protected content and anything under macOS
  Secure Event Input are never read or pasted into. That includes a field inside
  a secure or protected element: Enigma checks the focused element and every
  element above it, up to the app itself. If Enigma can't tell whether a field is
  safe, for example because it can't reach the app within 128 levels, it doesn't
  read it.
- Only the focused element and the web page that contains it are read. For a
  web page, Enigma asks for the page's own selection (its text markers); it
  never reads other pages, windows or the rest of the document. When the
  focused element is itself a web page (a frame or an embedded web view),
  Enigma reads only that page, never the page around it.
- Typing, clicking, scrolling, pressing a modifier key or switching apps during a
  capture cancels it. Letting go of the shortcut's keys (for example ⇧⌥ after
  ⇧⌥Space) doesn't.
- The selection is limited to 256,000 bytes; larger selections are refused with a
  notice. A model's context limit can be smaller, in which case the request is
  refused and your draft is kept.
- Some apps don't expose selected text to Accessibility. For those Enigma may copy
  the selection with **⌘C** and read it from the clipboard. Every item and format
  on your clipboard is saved first and put back afterwards, unless you copied
  something new in the meantime. If the clipboard can't be saved completely, the
  copy isn't attempted. VS Code and editors built on it (VS Code Insiders,
  VSCodium, Cursor, Windsurf) copy the whole current line when nothing is
  selected, so Enigma uses their copy only when VS Code's own clipboard data says
  it came from a real selection. A copy from several cursors with nothing
  selected is rejected too, so in that case Enigma reads no text.
  Enigma doesn't add Electron apps such as Claude, Slack and Discord as cases
  where ⌘C is allowed despite an empty selection range (as it does for browsers):
  their selections are read through text markers instead, and a ⌘C there could
  copy something other than the selection. As for any other app, ⌘C is still
  tried when the focused element reports no selection range at all.

### Temporary chats and what is saved

While the chat is in the panel it lives only in memory: nothing is written to
disk and it doesn't count toward saved chats. It's discarded when you invoke the
selection shortcut again, start a new chat, switch to another chat, or quit.
Closing the panel without opening the chat in the window saves nothing.

The selected text itself is never written to disk, even in a saved chat: the
saved chat keeps your messages and the replies. Replies can still quote parts of
the selection, such as an **/edit** draft or a translation; turn on
**Keep selection chats private** to save nothing from selection chats. Once you
leave a saved selection chat, its selection and **Replace text** are gone, and
earlier revisions show as quoted text.

### Models and search

The chat uses your selected mode and model, local or cloud. In Cloud mode, or when
Auto picks a cloud model, the selection is sent to that provider along with your
question. With **/search**, or automatic search when it's on, the model first
writes a search query from your question and the selection, so relevant details
from the selection can reach Brave Search. It uses the same query-writing prompt
as screenshots: the selection is quoted data, never instructions, and the model
is told to leave out unrelated content, credentials and personal details, though
that isn't guaranteed. Your slash commands are removed before the query is
written. Only your own question decides whether automatic search runs. See
[Web search](Web-Search.md) and [Chat](Chat.md).

## How it works

- **Shortcuts.** `SelectionShortcutMonitor` and `OptionDoubleTap`
  (`Enigma/App/SelectionShortcut.swift`) detect the double tap from global and local
  `flagsChanged` monitors; settings live under the `enigma.selection.*` defaults keys.
  `GlobalHotKeyMonitor` (`Enigma/App/GlobalHotKeyMonitor.swift`) registers
  **⇧⌥Space** as a Carbon hot key, and `PanelShortcutMonitor` handles **⌥⌃**, a tap that fires when Option and Control are
  released after being pressed together with no other key, modifier or click. They
  are started in `ApplicationDelegate` (`Enigma/App/ApplicationDelegate.swift`).
  `OptionDoubleTap.tap` reports a first complete tap separately from the double
  tap, and `SelectionShortcutMonitor` calls its `firstTap` closure then.
  `SelectionAccessibilityWarmer` (also in `Enigma/App/SelectionShortcut.swift`)
  is called there, and on
  `NSWorkspace.didActivateApplicationNotification`,
  `didLaunchApplicationNotification` (for an app that launches in front) and
  startup, to set `AXManualAccessibility` on the frontmost app other than Enigma
  when Accessibility is granted, skipping the VS Code family
  (`SelectionCapturePolicy.codeEditors`, or a bundle containing
  `Contents/Resources/app/product.json`; `isWarmable`) and any app whose bundle ID
  or bundle URL is unknown. `SelectionWarmHistory` remembers the last warms, by pid
  and launch date, for the log. After an activation or launch it repeats the set
  at `retryDelays` (1 s, 3 s, 8 s) while that app is still frontmost and
  Accessibility is still granted; a newer activation or `stop()` makes earlier
  retries do nothing. The set runs on a background serial queue with a 0.25 s
  timeout, so a slow or hung app can't hold up Enigma's main thread.
  Help's rows and strings are in `KeyboardShortcutsHelp`
  (`Enigma/App/EnigmaMainWindowLogic.swift`) and
  `Enigma/App/KeyboardShortcutsHelpView.swift`.
- **Diagnostic log.** `SelectionLog` (in `SelectionContextService.swift`) writes one
  `.notice` line per capture that reaches the source app: focus wait in ms, number
  of focus reads, whether the tree was cold, selection read time in ms, which
  source gave the text, whether ⌘C was used, the result (`attached`,
  `nothingRead`, `notReady`, `tooLarge` or `cancelled`), and, from a snapshot taken
  before the capture starts waiting, how many seconds earlier the app was last
  warmed and by what (`lastWarm`, `lastWarmTrigger`) and when its last first-tap
  warm was (`firstTapWarm`). Each warm writes a `.debug` line with its trigger and
  `AXError` code, which macOS doesn't keep. Nothing logged contains the selected
  text, its length, or the app's name or bundle ID. Read the capture lines with:

  ```sh
  log show --predicate 'subsystem == "com.leow427.AISpotlight" AND category == "selection"' --last 1h
  ```

  and watch the warm lines live during a check with:

  ```sh
  log stream --level debug --predicate 'subsystem == "com.leow427.AISpotlight" AND category == "selection"'
  ```
- **Capture.** `SelectionContextService.capture()` (`Enigma/App/SelectionContextService.swift`)
  sets `AXManualAccessibility` on the frontmost app and runs
  `SelectionCaptureFlow.run`, a generic sequence over the tree that the service
  feeds with thin closures over the Accessibility calls. Structural lookups (the
  focused element, parents, roles, ranges, marker ranges) use a 0.15 s messaging
  timeout and string reads 1 s, instead of the system's 6 s default; the text
  timeout is longer than the selection retry, so a read that times out ends the
  retry. The flow waits up to 2.5 s
  (`focusBudget`, polling every 30 ms with `SelectionCaptureRetry.first(within:)`)
  for a focused element: a Chromium or Electron tree that was off takes about 2 s
  to appear, and Chromium turns it off again after a while. A ready app answers on
  the first read, so it doesn't wait. If an app's whole wait passes with no
  focused element, `SelectionFocusMemory` remembers that app (in memory, until it
  quits or reports a focused element) and later captures there wait only 300 ms.
  The wait stops at once on cancellation, user input, Secure Event Input or a
  change of frontmost app. The element must
  pass `SelectionAncestry.isSafe`, which walks up to 128 parents to the app and
  fails closed on a secure or protected node, a missing parent or never reaching
  the app (which also ends a parent cycle); after a cold wait an element that
  doesn't pass yet is retried for the rest of the 2.5 s. `SelectionCapturePolicy.selectionText`
  then tries, in order, and stops at the first text that isn't blank: the focused
  element's `AXSelectedText`; `AXStringForRange` or the selected slice of `AXValue`;
  its `AXSelectedTextMarkerRange` read with `AXStringForTextMarkerRange`; and the
  same two reads (`AXSelectedText`, then markers) on its nearest `AXWebArea`
  ancestor, unless the focused element is a web area itself. The marker range is
  an opaque value passed back to the element it came
  from; no private API is linked. The selection is read up to three times, 30 ms
  apart, or for up to 750 ms (`coldSelectionBudget`) when the focused element only
  just appeared. Every read re-checks that the focus and its safety haven't
  changed; on a warm tree a changed focus ends the capture, while during the cold
  750 ms the flow follows the new focused element if it passes the same safety
  check (cold VS Code first reports its web area, then the editor), and that
  element is the one the rest of the capture uses. Text from markers places the panel with `AXBoundsForTextMarkerRange`.
  If nothing is read, `SelectionCapturePolicy` decides when the ⌘C
  fallback is allowed (browser canvas editors yes; editors that copy the whole line
  on an empty selection, no). VS Code-family editors use the fallback only when
  VS Code's clipboard metadata (`isFromEmptySelection` and `multicursorText` in
  `vscode-editor-data`, read from `org.chromium.web-custom-data`) confirms a single
  real selection; otherwise the copy is discarded. The metadata is read only for
  those editors. `SelectionPasteboardSnapshot` saves and restores the
  clipboard. `SelectionInteractionGuard` cancels on user input and tags Enigma's own
  synthetic events; `SelectionInteractionPolicy` decides which events count
  (releasing modifiers doesn't). The result is a `ConversationContext`
  (`Enigma/Chat/ConversationContext.swift`). When nothing is attached,
  `SelectionCaptureNotice` words the notice: it names the app ("No selected text
  could be read from Claude…"), or says the app didn't share its text in time when
  no focused element appeared within the wait.
- **Placement and panel geometry.** `SpotlightPanelController.summonSelectionContext()`
  (`Enigma/App/SpotlightPanelController.swift`) places the panel with
  `SelectionPanelPlacement`, resizes it from `SelectionComposerReport`s, grows it with
  `SelectionPanelExpansion` (720 pt wide, up to 600 pt tall, on
  `EnigmaMotion.panelAnswer`), and handles **⌘O** and the **Open in window**
  button (`.selectionChatOpenInWindowRequested`) through
  `openSelectionChatInWindow()`. Dragging uses `enigmaWindowDragArea`
  (`Enigma/App/EnigmaControls.swift`).
- **Panel views.** `EnigmaCompactPanel`, `EnigmaCompactSelectionLine`,
  `EnigmaCompactComposer`, `EnigmaCompactDetails`, `EnigmaCompactAnswer` and
  `EnigmaCompactHints` are in `Enigma/App/EnigmaCompactPanel.swift`; their labels and
  rules (`CompactPanelLayout`, `CompactSelectionStatus`, `CompactRouteChip`,
  `CompactPanelHints`, `CompactPanelCharacter`) are in
  `Enigma/App/EnigmaCompactPanelLogic.swift`. `AppShellView` (`Enigma/App/AppShellView.swift`)
  owns the state and actions; `ShellPresentation` (`Enigma/App/ShellPresentation.swift`)
  tracks whether the panel or the window layout is showing.
- **Cards.** `SelectionRevisionCard`, `SelectionContextCard` and
  `AccessibilityNeededCard` are in `Enigma/Chat/SelectionCards.swift`.
- **Chat and requests.** `LocalChatViewModel` (`Enigma/LocalInference/LocalChatViewModel.swift`)
  owns the temporary chat (`startTemporaryChat`, `openTemporaryChatInWindow`),
  decides which turns carry the selection (`requestContexts`, `sentContextIDs`), and
  handles revisions and recovery. `SelectionResponseMode` chooses the per-request
  instructions, `ConversationContextPrompt.expand` adds the selection to request
  copies as JSON marked as untrusted source material, and `SelectionRevisionResponse`
  parses the `<enigma-revision>` payload; only an **/edit** request with the
  selection attached can produce a card. Messages store contexts in memory only;
  they aren't part of the saved chat format. `SelectionEditingSettings` holds the
  two Selection settings.
- **Replacement.** `SelectionContextService.replace(with:contextID:)` runs
  `SelectionPasteTransaction`: check permission and the source app, activate it,
  check the focused field, snapshot the clipboard, write the text with transient
  and auto-generated markers, post ⌘V to the source process, wait 600 ms, restore.
- **Permission.** `SelectionAccessibilityAccess` (same file) tracks trust and opens
  System Settings; `MacPermissionRows` (`Enigma/Screen/MacPermissionRows.swift`)
  shows it in Settings and the welcome setup.

## Limitations

- Capture depends on each app's Accessibility support. Some apps expose nothing,
  in which case the panel opens with `› no text selected` and a notice that names
  the app and suggests you copy and paste the text yourself. See
  [App support](#app-support).
- The panel can still open about 2 s late in a Chromium or Electron app (Slack,
  Discord) if you invoke Enigma within about 2 s of the moment the app accepted
  the request to turn on accessibility, for example right after it launched (the
  retries ask again at about 1 s, 3 s and 8 s); a key press, click or scroll during
  that wait cancels the capture. VS Code-family editors aren't pre-warmed, so the first capture there after
  their accessibility was off still takes about 2 s.
- An app that has nothing focused, or never reports a focused element (such as
  OpenAI's Codex app, below), delays the panel by the full 2.5 s wait once, then by
  300 ms on later invocations in that app until it reports a focused element.
- An app that is busy or stops responding can still hold up the panel: each
  lookup gives up after 0.15 s and each text read after 1 s, and a text read that
  times out ends the selection retry, so the delay is bounded (a few seconds at
  worst) rather than the system's 6 s per call.
- A very large selection that takes the app longer than 1 s to hand over isn't
  read through Accessibility; Enigma falls back to ⌘C where that's allowed, and
  otherwise attaches nothing.
- Replacement is a normal paste. An app that is slow to paste may read the
  clipboard after Enigma has restored it, and Enigma can't confirm the paste landed.
- Automated tests use synthetic fixtures and an `NSTextView`; behavior in specific
  editors (web editors, word processors, Electron apps) has to be checked by hand.
  Use a stably signed build run from Xcode for that, not the unsigned build from
  `scripts/verify-xcode.sh`, which can invalidate macOS consent.
- Translation quality and how well a model follows **/edit** depend on the model;
  the permission to replace text is enforced by Enigma.
- Moving the panel by dragging doesn't move it between Spaces.

## App support

On 2026-10-23 a signed build with the capture fixes, before pre-warming was
added, attached the selection in Claude (the message box and a reply), Slack
(freshly relaunched, double Option), Discord (⇧⌥Space) and Safari (page text),
with the first capture in a cold app still taking about 2 s. With pre-warming
and its retries, the first capture in Slack and Discord was fast as well (its
first version, without retries, was still slow in a freshly launched Slack). The
rest of the table comes from the probe.

Results from `scripts/selection-probe.swift` on macOS 27 (October 2026), with read-only
text (for example a reply or a web page) and text in an input. "Cold" means the
first query after the app started or its accessibility tree had been turned off;
the time is how long the focused element took to appear after
`AXManualAccessibility` was set. The ⌘C column says whether the fallback would be
used if the Accessibility reads came up empty.

| App | Bundle ID | Read-only text | Text in an input | Focus after enabling | ⌘C fallback | Notes |
|---|---|---|---|---|---|---|
| Claude | `com.anthropic.claudefordesktop` | `AXGroup` (sometimes subrole `AXApplicationGroup`): `AXSelectedText`, `AXStringForRange` and text markers all return it | `AXTextArea` (message box): `AXSelectedText` | 2–3 ms (tree already on) | Not used | The app is 31–37 parents above the focused element (the message box: 36). Capture failed before because the walk stopped at 32. Verified on 2026-10-23 (message box and reply). |
| Slack | `com.tinyspeck.slackmacgap` | `AXGroup`: `AXSelectedText` empty, range length 0; text markers on the focused element return it, and so does the `AXWebArea` ancestor's `AXSelectedText` | not tested | 2059 ms (cold) | Not used (range length 0, not a browser) | Failed before; verified on 2026-10-23 after a fresh relaunch (double Option), with the cold delay. |
| Discord | `com.hnc.Discord` | `AXWebArea` focused with `AXSelectedTextMarkerRange` (no selection tested) | not tested | 2077 ms (cold); once none within 2 s | Not used | Verified on 2026-10-23 (⇧⌥Space). |
| VS Code | `com.microsoft.VSCode` | — | `AXTextArea` (editor): `AXSelectedText` | 2033 ms (cold) | Only when VS Code's metadata confirms a selection | |
| Safari | `com.apple.Safari` | `AXWebArea`: `AXSelectedText` and range empty; text markers return it | `AXTextField`: `AXSelectedText` | 2 ms | Allowed (browser), now rarely needed | `AXManualAccessibility` unsupported. Page text verified on 2026-10-23. |
| Chrome | `com.google.Chrome` | `AXGroup` (subrole `AXTabPanel`): `AXSelectedText`; sometimes the `AXWebArea` is focused with range length 0 and no markers | `AXTextField`: `AXSelectedText` | 322 ms | Allowed (browser) | |
| Messages | `com.apple.MobileSMS` | `AXTextArea`: `AXSelectedText` | `AXTextField`: `AXSelectedText` | 1287 ms (cold) | Not needed | |
| Notes | `com.apple.Notes` | `AXTextArea`: `AXSelectedText` | `AXTextArea`: `AXSelectedText` | 0 ms | Not needed | |
| Xcode | `com.apple.dt.Xcode` | — | `AXTextArea` (source editor): `AXSelectedText` | 1617 ms (cold) | Not needed | |
| Preview (PDF) | `com.apple.Preview` | `AXGroup` (subrole `AXSharedDocumentContainer`): `AXSelectedText`, no range | — | 0 ms | Not needed | |
| Terminal | `com.apple.Terminal` | `AXTextArea` lists `AXSelectedText` and a range (a real selection not tested) | — | 0 ms | — | |
| TextEdit | `com.apple.TextEdit` | — | `AXTextArea`: `AXSelectedText` | 0 ms | Not needed | |
| Pages | `com.apple.iWork.Pages` | Not determined: no selection was captured (focus on an `AXScrollArea`, an `AXList` or nothing) | — | 11 ms | — | Needs a retest. |
| ChatGPT (on the test Mac, OpenAI's Codex app) | `com.openai.codex` | No focused element at all and no `AXWebArea` under the window | — | none within 2 s | — | `AXManualAccessibility` unsupported. Unresolved. |

Not installed or not tested: Notion, Obsidian, Microsoft Word, Outlook, Teams,
Figma, Google Docs (in Chrome), Firefox, Arc, iTerm2, JetBrains IDEs, Zed,
WhatsApp and Mail.

### The selection probe

`scripts/selection-probe.swift` prints what an app exposes to Accessibility about
its current selection: the frontmost app and bundle ID, whether
`AXManualAccessibility` was accepted and how long the focused element took to
appear, the focused element's role and subrole, `AXSelectedText`,
`AXSelectedTextRange`, `AXStringForRange`, `AXValue`'s length, text markers, its
text attribute names, and the same for any `AXWebArea` ancestor and how many
levels up the app is. It only reads, apart from setting `AXManualAccessibility` as
Enigma does; it never touches the clipboard.

```sh
swift scripts/selection-probe.swift                      # 5 s to switch apps and select text, then read the frontmost app
swift scripts/selection-probe.swift com.tinyspeck.slackmacgap 2  # activate an app, wait 2 s, read it
swift scripts/selection-probe.swift --watch 300          # report each new selection for 5 minutes
```

The terminal running it needs Accessibility permission (**System Settings →
Privacy & Security → Accessibility**). Text is printed as a character count;
add `--text` to print the text itself, which you shouldn't do for private
documents.

## Tests

- `EnigmaTests/SelectionContextTests.swift`: the double-tap detector and its
  first-tap signal, the accessibility warmer, placement,
  AX fallbacks and their order, the ancestor walk, the capture flow over a fake
  tree on a simulated clock (cold trees, timeouts, interruptions, unsafe focus,
  a focus that moves, web areas, when ⌘C may follow), the per-app focus memory,
  which events cancel a capture, the
  capture notices, clipboard preservation, paste transactions
  and their failure paths, which turns carry the selection, **/edit** and
  **/translate** handling, revision recovery, automatic replacement, temporary and
  private chats, and panel expansion.
- `EnigmaTests/EnigmaCompactPanelTests.swift`: the panel's chip, placeholder, hints
  and character state; growing, resizing, dragging, the details, Escape, opening in
  the window (saved and private), and rendered screenshots.
- `EnigmaTests/ScreenViewTests.swift` covers screenshots captured from the panel.

Run one class with
`scripts/verify-xcode.sh test -only-testing:EnigmaTests/SelectionContextTests`.
See [Testing](Testing.md).

`SelectionContextTests/testInstalledGemmaHandlesSelectionCommands` is an opt-in
check against an installed local model whose ID contains `12b`. It uses synthetic
text and never pastes. Run it with:

```sh
TEST_RUNNER_ENIGMA_SELECTION_MODEL_SMOKE=1 scripts/verify-xcode.sh test \
  -only-testing:EnigmaTests/SelectionContextTests/testInstalledGemmaHandlesSelectionCommands
```
