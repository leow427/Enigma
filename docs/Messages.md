# Messages

Add `/messages` to a message and the selected model can read, search, and send
your Apple Messages (iMessage, SMS, and RCS) for that one request. Enigma reads
the Messages history on this Mac read-only, and sends only after you approve the
exact recipient and text.

Models that choose their own tools don't need the command: they have the
Messages tools on every message and use them when you ask about your messages,
behind a card that asks before any chat is read. See
[On models that choose their own tools](#on-models-that-choose-their-own-tools).

## Using `/messages`

Type `/messages` anywhere in your message, followed or preceded by what you want:

- `/messages what did Sam say about Saturday?`
- `/messages who have I talked to most this week?`
- `/messages tell Alex I'm running 10 minutes late`

The command applies only to the message that contains it, like `/search`. The
model can list recent conversations, page back through one conversation, search
message text across all conversations, look up contacts, and propose a message
to send.

`/messages` can't be combined with `/screen`, `/snapshot`, `/search`, an
attached screenshot, or attached files. Enigma shows an error instead of
sending, so message contents never become a web search query or share a request
with a screen capture.

### Without typing `/messages`

You can also just ask. When your message reads as a Messages request, Enigma
shows a `messages` chip in the composer before you send and runs the message as
if you'd typed `/messages`. A message reads as one when it has all three of:

- **A messaging word:** message, text, texted, iMessage, SMS, group chat or
  group text, "the family chat", "sent me", "got back to me", "answered my
  text", or "my conversation (or text thread) with …". "Replied" and
  "responded" count only in a question that is just about the reply: "has Dad
  replied yet", "has my brother responded yet", "did Alex reply", "check
  whether Alex replied". "Got back to me" counts in any question: "did Priya
  get back to me about the trip".
- **A person or your own messages:** a name, a relative or someone close such
  as "my dad", "my best friend" or "my boss", a pronoun, "the group chat", or
  "my texts". "My" followed by anything else, such as "my queue" or "my essay",
  isn't a person.
- **A request to read or send:** a question ("what did …", "has …", "any …"),
  or a verb such as check, read, show, pull up, go through, catch me up on,
  summarize, text, message, send, shoot, drop, reply, or "let … know … via
  text".

So all of these count:

- "what are the most recent messages from my dad", "did my sister message me
  today", "has Dad replied yet", "catch me up on the group chat", "what was
  Alex's last text", "summarize my conversation with Alex", "see if Alex got
  back to me"
- "read my last 5 messages", "show the texts between me and Alex", "how many
  unread messages do I have", "when is dinner according to Mom's text", "any
  SMS from the bank today?", "summarize what I missed in the family chat",
  "recap my text thread with my brother", "I'm behind on texts, who do I need
  to reply to", "can u check my messages from dad", "anything new from my wife
  in iMessage", "yo whats my sister been texting me"
- "text my dad that I'll be late", "send Alex a text saying I'm outside",
  "shoot Sam a text that I'm here", "reply to Jordan with sounds good", "let Mom
  know I landed via text", "message Mom: running late", "send a text message
  to the plumber confirming Thursday at 9", "reply to my moms text and say yes",
  "tell my boss via text that I'm running late"

When in doubt it doesn't match. These don't count:

- Noun compounds: "text classification", "message passing", "what does this
  error message mean"
- Other services: "send an email to Alex", "how do I send a message in Slack",
  unless iMessage or SMS is named
- "send me a summary", "text me a joke"
- How-to and advice questions: "how do I text …", "what's the best way to
  message a landlord", "what should I text my crush", "what do I say in a text
  to cancel plans", "text my ex or not?"
- Idioms: "send a clear message to investors in my pitch deck"
- Replies to Enigma itself: "just text back yes or no"
- Replies in the news: "did Microsoft respond to the allegations", "has the
  White House responded"
- Something someone sent you, pasted in: "Sam sent me this article, summarize
  it"
- Titles, lyrics and slang: "the song Text Me Back", "who sang Send Me a Text",
  "what does text me mean"
- This chat: "my last message", "your last message", "summarize our
  conversation", "this chat"
- Drafting and reviewing: "write a message to my landlord", "write my dad a
  text saying …", "read my message to my boss and tell me if it's too harsh"
  stay ordinary writing requests
- Questions without a messaging word, such as "what did Sam say about dinner"
  or "tell Sam I'm running late", unless they follow a Messages request (below)

**Follow-ups.** After a message that used Messages in this chat, typed or
recognized, a follow-up with a looser cue also uses it: "send it", "reply with
sounds good", "tell her I'm on my way", "text them back", "what about Alex?",
"what else did she say". An unrelated follow-up goes back to ordinary chat and
ends the carry-over, as do a new chat and switching chats. Enigma keeps only an
in-memory note that the previous request used Messages; it never reads earlier
messages to decide.

Click the chip to send that one message without Messages. Recognition never
causes the conflict error above: with files or a screenshot attached, or with
`/search`, `/screen` or `/snapshot` typed, `messages` simply isn't recognized.
A recognized `messages` keeps every safeguard below: the Full Disk Access check,
the one-time cloud notice, Auto staying on this Mac, and your approval for each
send. Recognition only happens with **Settings → General → Recognize commands
from your wording** on, and it's off by default. See [Slash commands](Slash-Commands.md#recognized-commands).

### On models that choose their own tools

Local models of about 9B and up, both mixture-of-experts models, and the cloud
models have a **native tools** flag (see
[Slash commands](Slash-Commands.md#models-that-choose-their-own-tools)). With
one of them selected, every message offers the Messages tools while Enigma has
Full Disk Access, and no files or screenshot are attached. Just ask: "what did
Sam say about Saturday?" Nothing is recognized from your wording and no chip is
shown; the model decides. Typing `/messages` still works: the model is told you
asked for Messages, and in Auto the request stays on the local model, as above.

Listing chats and looking up contacts are free: names, participants and times,
never message text. A chat's last-message preview appears in the list only
once that chat is allowed for where the reply goes. Message text is read only
after you answer a card.

#### Permission cards

The reply pauses on a card in the chat, in the style of the send card:

| Before | Card | Remembered |
| --- | --- | --- |
| Reading a chat (`get_messages`) | **Allow reading your chat with ‹name›?** | Per chat and destination |
| Searching all chats (`search_messages`) | **Search all your messages for “‹query›”?** | Per destination |
| A web search once message text is in the chat | **Search the web for “‹query›”?** *This chat includes text from your messages. It will be sent to Brave.* | Once, for every destination |
| ChatGPT's or Claude Code's own web search once message text is in the chat, or on a typed `/messages` turn | **Let ‹provider› search the web in this chat?** *This chat includes text from your messages. ‹provider›'s web search runs its own queries on ‹company›'s servers, and Enigma can't check each one.* | Per provider |

For the first two, the detail line names where the text goes: **It stays on
this Mac.** on a local route, or **It will be sent to OpenAI** (the OpenAI API
and ChatGPT via Codex), **Anthropic** (the Anthropic API and Claude Code) or
**Google** (Gemini). The answers are:

- **Don't allow** (Escape): the tool tells the model "The user declined." and it
  carries on without the data. Stop or a new chat while a card is open counts
  as Don't allow; other chats can't be opened while a card waits.
- **For this conversation:** kept in memory for this chat, never saved. It
  lasts until you delete the chat or quit Enigma, including when you go back
  to the chat from Recents; after Enigma restarts, the chat asks again.
- **Always:** saved in Enigma's settings (not the Keychain; it isn't a secret)
  and listed under **Settings → General → Messages → Always allowed**, one row
  per grant with a **Remove** button.

A card shows a query on one line, with hidden characters shown as `�`, and the
web search sends exactly what the card showed. Only your click answers a card:
nothing a model, a web page, a message or a file says can grant access.

#### Message text in a chat

Once any message text is in a chat (a read, a search hit, an allowed preview, or
an earlier typed `/messages` turn), Enigma marks the chat, saves the mark with
it, and from then on:

- each web search asks first with the third card;
- ChatGPT and Claude Code use their provider's own web search, which runs on
  the provider's servers where no card can ask for each query, only after the
  fourth card; declined, the reply has no search. If a read happens partway
  through a reply that has the provider's search before you've allowed it,
  its text is held back, never reaching that request, and the reply starts
  again after the card (see
  [Web search](Web-Search.md#cloud-models-own-search));
- in Auto the chat stays on the local model;
- a flagged cloud model asks **Send text from your messages to ‹company›?**
  (**Don't allow**, **Allow**, for this chat only) when the text was allowed for
  somewhere else, such as this Mac. Don't allow keeps your draft and sends
  nothing;
- routes that can't ask (a model without native tools in Cloud, a screenshot
  sent to the cloud, Codex File Mode) refuse with "This chat includes text from
  your messages, so it wasn't sent. Continue it with Local, or start a new
  chat."

Each read narrows the companies the chat may go to: text allowed only on this
Mac never reaches a company that saw earlier text in the chat, unless you choose
Allow. On these models the per-chat cards replace the one-time **Use Messages
with ‹provider›?** notice.

### Approving a send

Before anything is sent, a **Send this message?** card appears in the chat. It
shows:

- each recipient's name and handle (phone number or email), or the group name
  and every participant,
- the service (iMessage, SMS, or RCS), and
- the exact text.

Choose **Send** to send it, or **Don't Send** (Escape) to decline. Send has no
keyboard shortcut. Stopping the request or starting a new chat also declines.
There is no "always allow": every send needs its own approval, and one approval
sends one message. If the model tries to send the same text to the same
recipient twice in one request, the second send is refused.

When the model names a person rather than a handle, Enigma resolves it to one
recipient without guessing. Each contact card is its own person, even when two
cards share a name; two cards with the same name and exactly the same numbers
and emails count as one. If a name matches more than one person or group, the
model is told to ask you which one, from at most 20 choices: groups first, then
people sorted by name. People with different names are listed by name. People who share a name with
another person or with a matching group are told apart by each card's company
and its numbers and emails with their labels, led by the one a send would use
(their latest conversation's handle and chat_id, or else as below), for example
`Alex Kim (Example Co): mobile +15550001111, work alex@example.com`.

For one person's card, the conversation with the most recent activity is used,
on any of their handles. With no conversation yet, a phone number is used
rather than an email, and when there are several phone numbers the one
labelled mobile or iPhone. An email is used only for a contact with no phone
number. If that still leaves more than one equal choice, the model is told to
ask you which, with phone numbers listed first. The card shows the exact handle
before you approve.

After a send, Enigma checks the Messages history for up to three seconds and
reports either that the history shows the message as sent or that Messages
accepted it.
For a handle with no conversation yet, it looks for the one-to-one
conversation Messages creates, matching phone numbers on their last ten digits
and emails in any case. A message that Messages marked as failed, or that is
still being sent when the time runs out, is reported only as accepted. Only
messages that appear in the history after Enigma starts the send, and are dated
from then on, count, so an earlier copy of the same text can't confirm it. If
any of them with the same text failed, the send is reported only as accepted.
Messages can still mark a message as failed after Enigma has reported it as
sent; Messages itself shows that.

## Setup

Messages must be signed in on this Mac. Grant these permissions to **Enigma**,
meaning the copy you actually run (for example `/Applications/Enigma.app`, or
the build Xcode launches):

| Permission | Needed for | Where to grant it |
| --- | --- | --- |
| **Full Disk Access** | Reading and searching Messages history (`~/Library/Messages/chat.db`, opened read-only) | System Settings → Privacy & Security → Full Disk Access. Turn on Enigma, or click **+** and choose the app. Quit and reopen Enigma afterwards. |
| **Automation → Messages** | Sending messages | macOS asks the first time you approve a send. If you declined, open System Settings → Privacy & Security → Automation, expand Enigma, and turn on Messages. |
| **Contacts** (optional) | Showing names instead of phone numbers, and finding people by name | macOS asks the first time you use `/messages`. To change it later, open System Settings → Privacy & Security → Contacts. |

**Settings → General → Messages · /messages** shows the status of Full Disk
Access and Contacts, with an **Open Settings…** button while either is missing,
and an **Open Settings…** button for Automation. The rows refresh when you
return to Enigma. See [Welcome-and-Settings.md](Welcome-and-Settings.md).

If Full Disk Access is missing when you use `/messages`, Enigma explains it and
offers **Open Full Disk Access Settings…** without starting a request. If
Automation is denied during a send, or Full Disk Access is lost while a request
runs, the request stops there on every model route: no later tool call runs
(on Codex, a call already running alongside it may still finish), nothing is
retried, and the reply reads **Request failed** while a card explains the
problem with **Open Automation Settings…** or **Open Full Disk Access
Settings…**. The card goes away with a new chat, another chat, or a selection
chat.

macOS ties these permissions to the app's code signature. A copy built with a
different signing identity, such as the unsigned product of
`scripts/verify-xcode.sh`, needs them granted again. See
[Distribution.md](Distribution.md) for installing a signed copy.

### Choosing a model

- **Local** keeps Messages on this Mac, and so does **Auto** for a typed
  `/messages` or a chat that already holds message text. They need an
  installed local model and the `llama-server` runtime: **Settings → Local
  models → Files → Local file tools → Install**. When Auto picks the cloud for
  a message (a coding request, say), a model that chooses its own tools can
  read a chat there, after a card that names the company the text goes to.
- **Cloud** uses the preferred cloud provider and model from
  **Settings → Cloud and search**. Every provider is supported: OpenAI,
  Anthropic, and Gemini API keys, ChatGPT through Codex, and Claude through
  Claude Code.

## Privacy

- **Local:** Messages data stays on this Mac.
- **Auto:** a typed `/messages`, and a chat that already holds message text,
  stay on this Mac. A read that a model choosing its own tools starts goes to
  whichever model Auto picked, after its card.
- **Cloud:** the tool results the model asks for (message text, names, phone
  numbers, and email addresses, plus companies and Contacts labels when telling
  apart people who share a name with each other or with a group) are sent to the selected provider, the same
  place your chat already goes. Before the first cloud `/messages` request to
  each provider, Enigma asks **Use Messages with \<provider\>?**. Choosing
  **Continue** is remembered for that provider; **Cancel** sends nothing.
- **Models that choose their own tools:** no message text reaches any model,
  local or cloud, without a card answered for that chat (or for searching all
  chats) and that destination, and no web query leaves the Mac after message
  text entered the chat without its own card. A provider's own search runs
  after message text only once you've allowed it for that provider. The cards run in Enigma before a
  tool returns anything; see [Permission cards](#permission-cards).

| Provider | Destination |
| --- | --- |
| OpenAI API | `api.openai.com` |
| Anthropic API | `api.anthropic.com` |
| Gemini API | `generativelanguage.googleapis.com` |
| ChatGPT via Codex | OpenAI, through the local Codex app server |
| Claude via Claude Code | Anthropic, through the local Claude Code CLI |

Other safeguards:

- The database is opened read-only; Enigma never writes to it.
- Message contents, names, and contact details are untrusted. The tool
  instructions tell the model never to follow instructions found in them, and
  to send only when you asked in this request, to the recipient you named.
- Assistant text is never parsed for commands. Only structured tool calls run.
- Tool results are not saved in chat history. Your prompt and the model's
  answer are saved like any other chat, with a mark (no text) when the chat
  holds message text. **Always** grants are saved in settings; conversation
  grants never are.
- The system prompt on flagged routes marks every tool result as data from
  outside sources, never instructions.

## How it works

The capability lives in `Enigma/Messages/`:

| File | Responsibility |
| --- | --- |
| `MessagesDatabase.swift` | Opens `chat.db` through short-lived connections with a `mode=ro` URI, `SQLITE_OPEN_READONLY`, and `query_only`, and runs the conversation, message, and search queries. Distinguishes a missing database from one hidden by privacy controls. |
| `AppleMessageDate.swift` | Converts Apple-epoch timestamps (nanoseconds since 2001-01-01, or seconds in older databases) and formats local ISO 8601 times. |
| `AttributedBodyDecoder.swift` | Extracts the text from the `attributedBody` blob when `message.text` is empty. |
| `MessagesContacts.swift` | Resolves handles to names with the Contacts framework, once per request, keeping each card's company and handle labels. Phone numbers are matched on their last ten digits. Without Contacts access, raw handles are used. |
| `MessagesSender.swift` | Runs `/usr/bin/osascript -` with a constant AppleScript on standard input. The target and text are passed only as `on run argv` arguments, never interpolated into the script. |
| `MessagesTools.swift` | The tool definitions, instructions, argument validation, recipient resolution, and the send ledger. Shared by every model route. |
| `MessagesCoordinator.swift` | Holds the pending send approval, the problem shown in chat, and the per-provider cloud consent. |
| `MessagesCards.swift`, `MessagesControls.swift` | The approval and problem cards, the cloud consent alert, and the permission status text. |
| `MessagesSettingsSection.swift` | The Messages rows in Settings → General, and the **Always allowed** list. |
| `MessagesAccessGate.swift` | `MessagesAccessGate`, which `MessagesTools` asks before returning message text on flagged routes, and `CoordinatorMessagesGate`, which answers it with the permission cards. |

The permission cards live in `Enigma/Chat/`: `ToolPermissions.swift`
(`ToolDestination`, `ToolPermission`, `ToolGrantStore`, which keeps conversation
grants in memory, Always grants under `tools.alwaysGrants`, and each chat's
message-text mark), `ToolPermissionCoordinator.swift` (one open card at a time;
a second request is answered Don't allow) and `ToolPermissionCard.swift`.

### Tools

| Tool | Behavior |
| --- | --- |
| `list_conversations(limit, sort)` | Conversations by latest message (`recent` or `oldest`, up to 50), with participants, a last-message preview, and its time. On flagged routes the preview's text is left out for chats not yet allowed. |
| `get_messages(chat_id, limit, before)` | Up to 100 messages from one conversation, oldest first within the page. `before` takes the `next_before` cursor from the previous page. |
| `search_messages(query, limit)` | Case- and diacritic-insensitive text search across all conversations, newest first, up to 20 matches with two messages of context on each side. Scans at most the newest 100,000 messages and reports when it stopped early. |
| `search_contacts(query)` | Name, phone, or email lookup across Contacts and known Messages handles. |
| `send_message(recipient, text)` | Resolves the recipient (a `chat_id`, phone number, email, contact name, or group name), then waits for approval. Text is limited to 4,000 characters. |

Tapbacks are left out of previews and search, and shown in `get_messages` as a
short description such as "loved a message".

### Model routes

`MessagesIntentPolicy` (`Enigma/Messages/MessagesIntentPolicy.swift`)
recognizes Messages requests and follow-up cues in the typed draft, and
`ComposerIntent` (`Enigma/App/ComposerIntent.swift`) combines them with typed
commands. `LocalChatViewModel.previousTurnUsedMessages` is the in-memory
follow-up note, set when a Messages request is accepted and cleared by any other
accepted request, a new chat, or switching chats.
`ComposerSubmission.plan` (`Enigma/App/ComposerSubmission.swift`) turns a
resolved draft into a Messages request and rejects conflicting typed commands. `AppShellView` asks for cloud
consent, then `LocalChatViewModel.submitMessages`
(`Enigma/LocalInference/LocalChatViewModel.swift`) checks Full Disk Access and
the selected route before starting:

- **Local and Auto** run `LocalToolAgent` over `llama-server`, the same runtime
  as local File Mode.
- **Flagged routes** go to `LocalChatViewModel.submitNative` instead (see
  [Chat](Chat.md#native-tool-turns)), with `MessagesTools` gated by
  `CoordinatorMessagesGate`, alongside web search and the selection tools.
- **Cloud** runs the provider's native tool calling
  (`Enigma/Cloud/CloudToolCalling.swift`): OpenAI Responses function calls,
  Anthropic `tool_use`, and Gemini function calls through `CloudToolLoop`
  (at most 12 model turns, one tool call at a time); Codex dynamic tools in an
  ephemeral, read-only thread that declines every native approval; and Claude
  Code with an in-process MCP server that Enigma answers over the CLI's
  stream-json control protocol, with built-in tools disabled and only the
  Enigma tools allowed.

A tool result that macOS settings must fix, or one from a stopped request,
carries how it ends the request (`AgentToolResult.stop`). A permission stop ends
every route instead of returning to the model: `LocalToolAgent` and
`CloudToolLoop` throw its error, Codex records it, interrupts the turn and runs
no later call, and Claude Code throws it in place of the MCP reply and ends the
CLI process. A stopped (`.cancelled`) result ends the local, API and Claude
Code routes as cancelled; on Codex it goes back to the model, since the request
is already ending. Recoverable errors, such as invalid arguments,
a declined send or an ambiguous recipient, still go back to the model.
`submitMessages` shows a `MessagesError` with a settings pane in the problem
card, whose button is named after the pane.

## Limitations

- AppleScript can't send tapbacks, edits, unsends, threaded replies, or
  attachments, so Enigma can't either.
- A new recipient with no existing conversation is sent over iMessage.
- Search decodes message bodies in Enigma rather than using an index, so very
  large histories are searched newest first up to the scan limit.
- Local and Auto need a local model and the `llama-server` runtime.
- Enigma doesn't watch for new messages.
- Recognizing a Messages request without `/messages` follows English wording
  only and needs a messaging word, and a follow-up needs a cue in the new
  message. A chat reopened from
  history starts without the follow-up.
- Chats saved before native tools that used `/messages` carry no message-text
  mark, so their web searches don't ask first.
- Which companies a chat's message text was allowed for is kept in memory. A
  chat reopened after Enigma restarts counts it as allowed on this Mac only, so
  a cloud model asks again.

## Tests

- `EnigmaTests/MessagesTests.swift` covers Apple-epoch dates, `attributedBody`
  decoding (including truncated and malformed blobs), queries against a fixture
  database built in each test (ordering, group chats, tapbacks, paging, search
  context, read-only connections), permission errors, `osascript` argument
  passing, recipient resolution, send approval and decline, cancellation, the
  per-provider cloud consent, and `/messages` parsing.
- `EnigmaTests/MessagesToolCallingTests.swift` covers each provider's tool loop
  with recorded responses, the step limit, Codex and Claude Code tool isolation,
  the local tool agent, a terminal result stopping each route with its error,
  the Full Disk Access and runtime preflight checks, the settings card after a
  mid-request permission loss on the local, Anthropic and Codex routes (and no
  card after Stop, a new chat, switching or cycling chats, or a selection
  chat), Codex results going back to the model until the turn completes, and
  the follow-up note staying with the chat that used Messages.
- `EnigmaTests/ClaudeCodeSubscriptionTests.swift` covers the Claude Code route
  ending its CLI process with the Messages error on a terminal result.
- `EnigmaTests/ComposerIntentTests.swift` covers the Messages phrasings that are
  and aren't recognized (`MessagesIntentPolicyTests`), recognition next to
  files, screenshots and other commands, and follow-ups
  (`ComposerIntentResolveTests`).
- `EnigmaTests/ComposerIntentPhrasingTests.swift` is the phrasing corpus: about
  920 English drafts, each tagged `messages`, `think`, `search` or none, that
  must resolve as tagged, including the hard negatives above. Messages drafts
  must never get the `search` chip. A miss found later becomes a line in it.

- `EnigmaTests/ToolPermissionTests.swift` covers the grant store, each card's
  copy, asking once then honoring For this conversation and Always, Always kept
  per destination, Don't allow and Stop, previews only for allowed chats, the
  message-text mark, and the Always list's rows.
- `EnigmaTests/NativeToolRequestTests.swift` covers flagged turns: the gated
  tools, the search-after-messages card, the share card, Auto keeping a chat
  with message text local, and the routes that refuse it.

No test reads the real `chat.db` or sends a message. In the test host,
`MessagesDatabase.defaultURL` points at a missing file, so a test can't open it
by accident.
