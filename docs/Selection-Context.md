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
  model menu, and **↵** to send.
- **The hint row**: `/ commands`, `⌘O open in window`, `esc close`, and on the
  right `temporary · not saved`. A reply never runs in the panel: the chat moves
  to the window as soon as its request starts.

The status button opens a details area under the input with the selected-text
card, notices, and any permission or routing cards. It shows a warning icon, and
the character shows its problem state, when Accessibility is missing or the
selection couldn't be read. Details open on their own when a request or capture
fails. When the panel sits low on the screen, the command list and the mode menu
open above the input.

Sending the first question moves the chat into the main window's normal chat
layout as soon as its request starts, before any reply, as **⌘O** does (see
[Opening the chat in the main window](#opening-the-chat-in-the-main-window)):
the panel travels to the window's normal size, centered on its screen, and the
model loads and the answer streams in there. With **Reduce Motion** on, it gets
there at once. If the question then fails, or you stop it before it reaches the
chat, the problem shows in the window and the selection stays attached; with a
local model the question also stays in the composer to send again. A send that
doesn't start a request leaves the panel where it is: one Auto can't route, or
one that fails before it starts, opens the details with the problem, every time
you send it; one waiting for you to allow a screenshot upload waits for your
answer.

**Escape** closes, in order, the command list, an open menu, the details, and then
the panel. Hiding the panel keeps its chat until you start another one.

### Moving the panel

Drag the panel by any empty part of it, such as the padding around the input or
the middle of the hint row. It stays on the visible part of the screen under the
pointer, below the menu bar. Once moved, it grows and shrinks from where you put
it, for the command list, the mode menu or the details. The next invocation
places it beside the new selection again. This drag doesn't move the panel
between Spaces or offer window tiling.

### Asking about the selection

The selection goes with your **first message only**. After a reply arrives, the
selected-text card over the window's composer says it was sent with your first
message, and new questions are ordinary turns: the model can still refer back to
the selection in the conversation, but it isn't attached again. If the first
reply fails, or is stopped before any text arrives, the next message carries the
selection again.

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

After an automatic paste, Enigma stays hidden, as if you had pressed Escape, so
you stay in your app looking at the edited text. Summon Enigma again to see the
same chat. If the automatic paste fails, Enigma comes back to show why. After
you click **Replace text** yourself, Enigma comes back once the paste is sent.

### Opening the chat in the main window

The chat moves into the main window once you **send your first question**. You
can also move it before sending: press **⌘O** while the panel is focused, or
click the **Open in window** button. Either way the panel travels to the window's
normal size, centered on its screen, with the sidebar as
**Settings → General → Show sidebar** sets it, and the chat keeps the selection
for **/edit** and **Replace text**.

What happens to the chat depends on
**Settings → Selection → Keep selection chats private** (off by default):

- **Off**: the chat is an ordinary chat once it's in the window. It goes to the
  top of Recents as "New Chat", and is saved and titled from your first question
  once that question reaches the chat, as any new chat is. A line under the first
  exchange says "Saved to history · Enigma keeps your last 10 chats" until your
  next message. The button's tooltip reads "Open in window · saves to history".
- **On**: the chat stays temporary in the window. It isn't saved and doesn't
  appear in Recents. A line under the first exchange says "Private chat · not
  saved to history" until your next message, and `temporary · not saved` stays
  over the composer. The tooltip reads "Open in window · stays private".

The setting is read when the chat moves to the window; changing it later doesn't
save or delete a chat that's already open.

The question reaches the chat once its request is under way: with a text-only
local model after the model has prepared it, with a vision-capable local model
(every bundled one) when the reply's first words arrive, and with a cloud model
as soon as it's sent, or after the web search when it searches. Until then the
chat is in Recents as an empty "New Chat" but isn't written to disk, and it
doesn't count toward the ten saved chats. If the question fails or is stopped
before it arrives, the chat stays open empty; leave it, or an empty chat you
opened with ⌘O without sending, and it's removed, so abandoned questions never
fill Recents or push out an older chat. The selected text is never written on
any route; the question is written only once it's in the chat.


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
- Chromium browsers (Chrome, Edge, Brave, Arc, Dia, Vivaldi, Opera and Chromium)
  are also asked with `AXEnhancedUserInterface`, the switch a screen reader such
  as VoiceOver sets, because Chrome 156 ignores `AXManualAccessibility` and keeps
  its web pages hidden from Accessibility without it (another project reported the
  same from Chrome 155). Enigma never switches either one off; Chrome kept its
  full accessibility tree on for at least 15 minutes idle. If VoiceOver turns
  `AXEnhancedUserInterface` off when it quits, the tree stays off until Enigma asks
  again on the next activation or first tap. Window managers such as Rectangle
  switch it off for each window move and back on afterwards, so Chrome may rebuild
  its tree after a move (not measured). On
  Chrome 156 the tree cost about 23 MB with a few tabs open, and resizing its
  window through Accessibility still worked exactly and at once (checked on
  2026-10-26). Other apps aren't asked this way, because native apps can animate
  oddly with it.
- Enigma writes one diagnostic line per capture to the system log, with timings
  and fixed labels only: no text, app name or bundle ID (see
  [How it works](#how-it-works)).
- Password fields, secure text fields, protected content and anything under macOS
  Secure Event Input are never read or pasted into. That includes a field inside
  a secure or protected element: Enigma checks the focused element and every
  element above it, up to the app itself. If Enigma can't tell whether a field is
  safe, for example because it can't reach the app within 128 levels, it doesn't
  read it.
- Apart from Safari's PDF view (below), only the focused element and the web
  page that contains it are read. For a
  web page, Enigma asks for the page's own selection (its text markers); it
  never reads other pages, windows or the rest of the document. When the
  focused element is itself a web page (a frame or an embedded web view),
  Enigma reads only that page, never the page around it.
- A PDF that Safari shows as a page has no focused element and shares no
  selection. So whenever Safari reports no focused element, Enigma looks through
  the layout of Safari's front window for a PDF viewer, reading only element
  roles and their children (at most 200 elements, never their text). If it finds
  one, it checks the viewer and every element above it as above, and copies the
  selection with ⌘C.
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
Closing the panel before sending saves nothing. Once the chat moves to the
window it's listed at the top of Recents and written once its first question
lands, unless **Keep selection chats private** is on. A private chat kept in the
window is also discarded when you summon Enigma after more than 5 minutes away
from it (see [Chat.md](Chat.md)).

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
  startup, to set `attributes(for:)` on the frontmost app other than Enigma:
  `AXManualAccessibility`, plus `AXEnhancedUserInterface` for the bundle IDs in
  `SelectionCapturePolicy.chromiumBrowsers` (`turnOnAccessibility` sets each to
  true). This happens
  when Accessibility is granted, skipping the VS Code family
  (`SelectionCapturePolicy.codeEditors`, or a bundle containing
  `Contents/Resources/app/product.json`; `isWarmable`) and any app whose bundle ID
  or bundle URL is unknown. `SelectionWarmHistory` remembers the last warms, by pid
  and launch date, for the log. After an activation or launch it repeats the set
  at `retryDelays` (1 s, 3 s, 8 s) while that app is still frontmost and
  Accessibility is still granted; a newer activation or `stop()` makes earlier
  retries do nothing. The sets run on a background serial queue with a 0.25 s
  timeout each, so a slow or hung app can't hold up Enigma's main thread.
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
  the `AXError` code of each attribute it set, comma-separated (Chrome:
  `-25205,-25208`), which macOS doesn't keep. Nothing logged contains the selected
  text, its length, or the app's name or bundle ID. Read the capture lines with:

  ```sh
  log show --predicate 'subsystem == "com.leow427.AISpotlight" AND category == "selection"' --last 1h
  ```

  and watch the warm lines live during a check with:

  ```sh
  log stream --level debug --predicate 'subsystem == "com.leow427.AISpotlight" AND category == "selection"'
  ```
- **Capture.** `SelectionContextService.capture()` (`Enigma/App/SelectionContextService.swift`)
  sets the same attributes on the frontmost app (`turnOnAccessibility`) and runs
  `SelectionCaptureFlow.run`, a generic sequence over the tree that the service
  feeds with thin closures over the Accessibility calls. Structural lookups (the
  focused element, parents, roles, ranges, marker ranges) use a 0.15 s messaging
  timeout and string reads 1 s, instead of the system's 6 s default; the text
  timeout is longer than the selection retry, so a read that times out ends the
  retry. The flow waits up to 2.5 s
  (`focusBudget`, polling every 30 ms with `SelectionCaptureRetry.first(within:)`)
  for a focused element: a Chromium or Electron tree that was off takes about 2 s
  to appear, and an Electron app may turn it off again after a while (Chrome,
  asked with `AXEnhancedUserInterface`, kept it on for at least 15 minutes). A
  ready app answers on
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
- **Safari's PDF view.** Safari shows a PDF opened as a page through a viewer
  (subrole `AXPDFPluginSubrole`) that never reports a focused element or its
  selection. So in Safari and Safari Technology Preview only, when the first focus
  read finds nothing, `SelectionCaptureFlow` looks once in the focused window for
  that viewer (`SelectionPDFViewer`): breadth-first, queueing only split groups,
  tab groups, groups and scroll areas (never a web area, a toolbar or the viewer's
  pages), within 8 levels and 200 elements (the window and each child whose role
  is read), stopping at the first check after 100 ms, and reading roles,
  subroles and children only. A viewer that passes the same
  `SelectionAncestry.isSafe` walk takes the focused element's place: the flow
  skips the focus wait and the selection reads, yields once (30 ms) so input
  during the lookup can cancel the capture, and goes to the ⌘C fallback. Finding
  a safe one also clears Safari from `SelectionFocusMemory`. Before, during and
  after the copy, `SelectionPDFViewer.isCurrent` replaces the same-focus check: Safari
  must still be frontmost and report no focused element (exactly
  `kAXErrorNoValue`; any other error fails), the element must still be a PDF
  viewer in Safari's focused window, and it must still pass the safety walk.
- **Placement and panel geometry.** `SpotlightPanelController.summonSelectionContext()`
  (`Enigma/App/SpotlightPanelController.swift`) places the panel with
  `SelectionPanelPlacement`, resizes it from `SelectionComposerReport`s, and moves
  its chat into the window through `openSelectionChatInWindow()`: a question
  whose request has started (`finishSendFromPanel()` after
  `AppShellView`'s submit paths), **⌘O** and the **Open in window** button all
  post `.selectionChatOpenInWindowRequested`. The controller posts
  `.selectionChatOpenedInWindow`, which switches the shell to the window layout
  and calls `LocalChatViewModel.openTemporaryChatInWindow()`, then moves the
  panel to the window's normal frame with `SelectionPanelMotion` on
  `EnigmaMotion.screenChange`. `.selectionPanelSettled` restores the window
  layout's minimum height once it arrives; a drag or a live resize settles the
  move first. Dragging uses `enigmaWindowDragArea`
  (`Enigma/App/EnigmaControls.swift`).
- **Panel views.** `EnigmaCompactPanel`, `EnigmaCompactSelectionLine`,
  `EnigmaCompactComposer`, `EnigmaCompactDetails` and `EnigmaCompactHints` are
  in `Enigma/App/EnigmaCompactPanel.swift`; their labels and rules
  (`CompactPanelLayout`, `CompactSelectionStatus`, `CompactRouteChip`,
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
- **Replacement.** `SelectionContextService.replace(with:contextID:automatic:)` runs
  `SelectionPasteTransaction`: check permission and the source app, activate it,
  check the focused field, snapshot the clipboard, write the text with transient
  and auto-generated markers, post ⌘V to the source process, wait 600 ms, restore.
  It posts `.selectionReplacementBegan`, which orders the window out, and
  `.selectionReplacementEnded` with a `SelectionReplacementEnd`: after a sent
  automatic paste `SpotlightPanelController` hides the window as a normal hide
  does (unless it was summoned again during the paste); otherwise it brings the
  window back.
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
- Text selected in a PDF that Safari shows as a page is read only by copying it,
  so it attaches only when Safari's ⌘C copies it, and the panel opens beside the
  pointer rather than the selection. **Replace text** can't paste into it (there's
  no focused field) and says the replacement couldn't be sent. Other WebKit apps
  that show the same viewer aren't searched.
- Of the Chromium browsers, only Chrome has been checked; the others are assumed
  to behave the same, and like Chrome they may fall back to ⌘C when the focused
  element reports an empty selection range. Installed web apps (which run under
  their own bundle IDs, such as `com.google.Chrome.app.…`) aren't on the list and
  haven't been tested; they get only `AXManualAccessibility`.
- An app other than Safari's PDF view that has nothing focused, or never reports
  a focused element (such as OpenAI's Codex app, below), delays the panel by the full 2.5 s wait once, then by
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
`AXManualAccessibility` (and in Chrome `AXEnhancedUserInterface`) was set. The ⌘C column says whether the fallback would be
used if the Accessibility reads came up empty.

| App | Bundle ID | Read-only text | Text in an input | Focus after enabling | ⌘C fallback | Notes |
|---|---|---|---|---|---|---|
| Claude | `com.anthropic.claudefordesktop` | `AXGroup` (sometimes subrole `AXApplicationGroup`): `AXSelectedText`, `AXStringForRange` and text markers all return it | `AXTextArea` (message box): `AXSelectedText` | 2–3 ms (tree already on) | Not used | The app is 31–37 parents above the focused element (the message box: 36). Capture failed before because the walk stopped at 32. Verified on 2026-10-23 (message box and reply). |
| Slack | `com.tinyspeck.slackmacgap` | `AXGroup`: `AXSelectedText` empty, range length 0; text markers on the focused element return it, and so does the `AXWebArea` ancestor's `AXSelectedText` | not tested | 2059 ms (cold) | Not used (range length 0, not a browser) | Failed before; verified on 2026-10-23 after a fresh relaunch (double Option), with the cold delay. |
| Discord | `com.hnc.Discord` | `AXWebArea` focused with `AXSelectedTextMarkerRange` (no selection tested) | not tested | 2077 ms (cold); once none within 2 s | Not used | Verified on 2026-10-23 (⇧⌥Space). |
| VS Code | `com.microsoft.VSCode` | — | `AXTextArea` (editor): `AXSelectedText` | 2033 ms (cold) | Only when VS Code's metadata confirms a selection | |
| Safari | `com.apple.Safari` | `AXWebArea`: `AXSelectedText` and range empty; text markers return it | `AXTextField`: `AXSelectedText` | 2 ms | Allowed (browser); the only way to read a PDF | `AXManualAccessibility` unsupported. Page text verified on 2026-10-23. A PDF opened as a page (`AXGroup`, subrole `AXPDFPluginSubrole`, five levels below the window) reports no focused element and no selection: `AXSelectedText` is listed on its text but stays empty (checked on 2026-10-26), so Enigma copies it. |
| Chrome | `com.google.Chrome` | `AXGroup` (subrole `AXTabPanel`): `AXSelectedText`; sometimes the `AXWebArea` is focused with range length 0 and no markers | `AXTextField`: `AXSelectedText` | 2088 ms (cold) | Allowed (browser, as in every Chromium browser) | Chrome 156 rejects `AXManualAccessibility` (-25205) and showed no focused element for 6 s on any page; `AXEnhancedUserInterface` answers -25208 but builds the tree (checked on 2026-10-26). Its PDF viewer then gives the selection through `AXSelectedText` (verified on 2026-10-26). The 322 ms measured on 2026-10-23 (Chrome version not recorded; not a cold tree) no longer reproduces. |
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
`AXManualAccessibility` (and in a Chromium browser `AXEnhancedUserInterface`)
was accepted and how long the focused element took to appear (it waits up to
3 s), the focused element's role and subrole, `AXSelectedText`,
`AXSelectedTextRange`, `AXStringForRange`, `AXValue`'s length, text markers, its
text attribute names, and the same for any `AXWebArea` ancestor and how many
levels up the app is. It only reads, apart from setting those attributes as
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
  first-tap signal, the accessibility warmer and which attributes it sets, placement,
  AX fallbacks and their order, the ancestor walk, the capture flow over a fake
  tree on a simulated clock (cold trees, timeouts, interruptions, unsafe focus,
  a focus that moves, web areas, a PDF viewer standing in for focus, when ⌘C may
  follow), the PDF viewer search, the per-app focus memory,
  which events cancel a capture, the
  capture notices, clipboard preservation, paste transactions
  and their failure paths, which turns carry the selection, **/edit** and
  **/translate** handling, revision recovery, automatic replacement, temporary and
  private chats, and moving the panel into the window.
- `EnigmaTests/EnigmaCompactPanelTests.swift`: the panel's chip, placeholder, hints
  and character state; resizing, dragging, the details, Escape, moving into the
  window by sending, ⌘O or Open in window (saved and private), a vision model's
  question moving before its first token, a first question that fails, a send
  that starts no request, abandoned sends (with Recents full too), a send that
  lands with Recents full, ⌃Tab while the panel is busy, an empty window chat's
  problem shown only on the page, and rendered screenshots.
- `EnigmaTests/SelectionContextTests.swift` also covers the window staying
  hidden after an automatic paste and coming back after a manual or failed one.
- `EnigmaTests/ScreenViewTests.swift` covers screenshots captured from the panel,
  and an Auto limitation opening the panel's details on every send.

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
