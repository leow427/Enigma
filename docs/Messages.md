# Messages

Add `/messages` to a message and the selected model can read, search, and send
your Apple Messages (iMessage, SMS, and RCS) for that one request. Enigma reads
the Messages history on this Mac read-only, and sends only after you approve the
exact recipient and text.

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
send. **Settings → General → Recognize commands from your wording** turns
recognition off. See [Slash commands](Slash-Commands.md#recognized-commands).

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
recipient without guessing. If a name matches more than one person or group,
the model is told to ask you which one. For a person with several handles, the
conversation with the most recent activity is used; the card shows the handle
before you approve.

After a send, Enigma checks the Messages history for up to three seconds and
reports either that the message appears there or that Messages accepted it.

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
Automation is denied during a send, the request stops with **Open Automation
Settings…**.

macOS ties these permissions to the app's code signature. A copy built with a
different signing identity, such as the unsigned product of
`scripts/verify-xcode.sh`, needs them granted again. See
[Distribution.md](Distribution.md) for installing a signed copy.

### Choosing a model

- **Local** and **Auto** keep Messages on this Mac. They need an installed
  local model and the `llama-server` runtime: **Settings → Local models →
  Files → Local file tools → Install**. Auto never sends Messages data to a
  cloud provider, even when cloud is configured.
- **Cloud** uses the preferred cloud provider and model from
  **Settings → Cloud and search**. Every provider is supported: OpenAI,
  Anthropic, and Gemini API keys, ChatGPT through Codex, and Claude through
  Claude Code.

## Privacy

- **Local and Auto:** Messages data stays on this Mac.
- **Cloud:** the tool results the model asks for (message text, names, phone
  numbers, and email addresses) are sent to the selected provider, the same
  place your chat already goes. Before the first cloud `/messages` request to
  each provider, Enigma asks **Use Messages with \<provider\>?**. Choosing
  **Continue** is remembered for that provider; **Cancel** sends nothing.

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
  answer are saved like any other chat.

## How it works

The capability lives in `Enigma/Messages/`:

| File | Responsibility |
| --- | --- |
| `MessagesDatabase.swift` | Opens `chat.db` through short-lived connections with a `mode=ro` URI, `SQLITE_OPEN_READONLY`, and `query_only`, and runs the conversation, message, and search queries. Distinguishes a missing database from one hidden by privacy controls. |
| `AppleMessageDate.swift` | Converts Apple-epoch timestamps (nanoseconds since 2001-01-01, or seconds in older databases) and formats local ISO 8601 times. |
| `AttributedBodyDecoder.swift` | Extracts the text from the `attributedBody` blob when `message.text` is empty. |
| `MessagesContacts.swift` | Resolves handles to names with the Contacts framework, once per request. Phone numbers are matched on their last ten digits. Without Contacts access, raw handles are used. |
| `MessagesSender.swift` | Runs `/usr/bin/osascript -` with a constant AppleScript on standard input. The target and text are passed only as `on run argv` arguments, never interpolated into the script. |
| `MessagesTools.swift` | The tool definitions, instructions, argument validation, recipient resolution, and the send ledger. Shared by every model route. |
| `MessagesCoordinator.swift` | Holds the pending send approval, the problem shown in chat, and the per-provider cloud consent. |
| `MessagesCards.swift`, `MessagesControls.swift` | The approval and problem cards, the cloud consent alert, and the permission status text. |
| `MessagesSettingsSection.swift` | The Messages rows in Settings → General. |

### Tools

| Tool | Behavior |
| --- | --- |
| `list_conversations(limit, sort)` | Conversations by latest message (`recent` or `oldest`, up to 50), with participants, a last-message preview, and its time. |
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
- **Cloud** runs the provider's native tool calling
  (`Enigma/Cloud/CloudToolCalling.swift`): OpenAI Responses function calls,
  Anthropic `tool_use`, and Gemini function calls through `CloudToolLoop`
  (at most 12 model turns, one tool call at a time); Codex dynamic tools in an
  ephemeral, read-only thread that declines every native approval; and Claude
  Code with an in-process MCP server that Enigma answers over the CLI's
  stream-json control protocol, with built-in tools disabled and only the
  Enigma tools allowed.

## Limitations

- AppleScript can't send tapbacks, edits, unsends, threaded replies, or
  attachments, so Enigma can't either.
- A new recipient with no existing conversation is sent over iMessage.
- Search decodes message bodies in Enigma rather than using an index, so very
  large histories are searched newest first up to the scan limit.
- Local and Auto need a local model and the `llama-server` runtime.
- Answers from the OpenAI, Anthropic, and Gemini API routes appear as each
  model turn finishes rather than streaming token by token.
- Enigma doesn't watch for new messages.
- Recognizing a Messages request without `/messages` follows English wording
  only and needs a messaging word, and a follow-up needs a cue in the new
  message. A chat reopened from
  history starts without the follow-up.

## Tests

- `EnigmaTests/MessagesTests.swift` covers Apple-epoch dates, `attributedBody`
  decoding (including truncated and malformed blobs), queries against a fixture
  database built in each test (ordering, group chats, tapbacks, paging, search
  context, read-only connections), permission errors, `osascript` argument
  passing, recipient resolution, send approval and decline, cancellation, the
  per-provider cloud consent, and `/messages` parsing.
- `EnigmaTests/MessagesToolCallingTests.swift` covers each provider's tool loop
  with recorded responses, the step limit, Codex and Claude Code tool isolation,
  the local tool agent, the Full Disk Access and runtime preflight checks, and
  the follow-up note staying with the chat that used Messages.
- `EnigmaTests/ComposerIntentTests.swift` covers the Messages phrasings that are
  and aren't recognized (`MessagesIntentPolicyTests`), recognition next to
  files, screenshots and other commands, and follow-ups
  (`ComposerIntentResolveTests`).
- `EnigmaTests/ComposerIntentPhrasingTests.swift` is the phrasing corpus: about
  920 English drafts, each tagged `messages`, `think`, `search` or none, that
  must resolve as tagged, including the hard negatives above. Messages drafts
  must never get the `search` chip. A miss found later becomes a line in it.

No test reads the real `chat.db` or sends a message.
