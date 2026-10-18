# Messages

`/messages` lets the selected model read, search, and (with your approval) send
Apple Messages — iMessage, SMS, and RCS — on this Mac. There is no public Apple
API for this, so Enigma reads the local Messages database and drives
Messages.app with AppleScript.

## Design

The capability lives in `AI-Spotlight/Messages/`:

| Unit | Responsibility |
| --- | --- |
| `MessagesDatabase` | Opens `~/Library/Messages/chat.db` with `file:…?mode=ro` and `SQLITE_OPEN_READONLY`, sets `query_only`, and runs the conversation, message, and search queries. It never writes. |
| `AppleMessageDate` | Converts Apple-epoch timestamps (nanoseconds since 2001-01-01, or seconds in older databases). |
| `AttributedBodyDecoder` | Extracts the string from the `attributedBody` typedstream blob when `message.text` is `NULL`. |
| `MessagesContacts` | Resolves phone numbers and emails to names with the Contacts framework, and searches contacts. Without Contacts access it falls back to raw handles. |
| `MessagesSender` | Runs `/usr/bin/osascript -` with a constant script on standard input. Recipient and text are passed only through `on run argv`, never interpolated. |
| `MessagesTools` | The tool definitions and executor shared by every model route. |
| `MessagesCoordinator` | Holds the pending send approval shown in the chat UI. |

### Tools

| Tool | Behavior |
| --- | --- |
| `list_conversations(limit, sort)` | Chats ordered by latest message (`recent` or `oldest`), with display name, participants, last-message preview, and timestamp. |
| `get_messages(chat_id, limit, before)` | Messages from one chat, oldest-first within the page. `before` is the `next_before` cursor from the previous page. |
| `search_messages(query, limit)` | Case- and diacritic-insensitive text search over `text` and decoded `attributedBody`, with two surrounding messages on each side. Scans at most the newest 100,000 candidates and reports when it stopped early. |
| `search_contacts(query)` | Name, phone, or email lookup across Contacts and known Messages handles. |
| `send_message(recipient, text)` | Resolves the recipient to a chat or handle, then waits for explicit approval. |

Reactions (tapbacks) are excluded from previews and search but are shown in
`get_messages` as a short description.

### Model routes

`/messages` applies only to the message that contains it, like `/search`.

- **Auto and Local** run a local tool loop over `llama-server`, the same runtime
  as local File Mode. Auto never sends Messages data to a cloud provider.
- **Cloud** runs a native tool loop for the selected provider: Codex dynamic
  tools, OpenAI Responses function calls, Anthropic `tool_use`, Gemini function
  calls, or Claude Code with an in-process MCP server over its stream-json
  control protocol.

Assistant text is never parsed for commands. Only structured tool calls run.

### Safety

- **Every send needs approval.** The card shows each resolved recipient (name
  and handle, or the group name and all participants), the service, and the
  exact text. Choosing **Don't Send**, stopping the request, or starting a new
  chat declines it. There is no "always allow".
- One approval sends one message. A repeated identical send in the same request
  is refused rather than sent twice.
- Message contents are untrusted data. The tool instructions tell the model
  never to follow instructions found in messages and to send only when you
  asked it to.
- `/messages` cannot be combined with `/search`, Screen, or File Mode, so
  message contents never become a web search query.
- Enigma does not log message bodies. Tool results are not saved to chat
  history; your prompt and the model's answer are saved as for any chat.

### Where data goes

With a local model, Messages data stays on this Mac. With a cloud model, the
tool results the model requests (names, handles, and message text) are sent to
that provider only — the same place Enigma already sends your chat:

| Provider | Destination |
| --- | --- |
| OpenAI | `api.openai.com` |
| Anthropic | `api.anthropic.com` |
| Gemini | `generativelanguage.googleapis.com` |
| ChatGPT via Codex | OpenAI, through the local Codex app server |
| Claude via Claude Code | Anthropic, through the local Claude Code CLI |

Enigma asks once per provider before the first cloud Messages request.
Claude Code receives the tools through an in-process MCP server that Enigma
answers over the CLI's stream-json control protocol; built-in tools stay
disabled and only the Enigma tools are allowed.
Elsewhere, Enigma sends web search queries (and approximate area for nearby
questions) to Brave, and downloads models and runtimes from Hugging Face and
GitHub; neither receives Messages data.

## Setup

See the Messages section of the [README](../README.md#messages-messages) for
Full Disk Access, Automation, and Contacts. Settings → General → Messages shows
each permission's status.

## Verification

`MessagesTests.swift` and `MessagesToolCallingTests.swift` cover Apple-epoch
dates, `attributedBody` decoding (archives written by Foundation, truncated and
malformed blobs), the query layer against a fixture database built in each test
(ordering, group chats, tapbacks, paging, search context, scan limits, read-only
connections), permission errors, recipient resolution, send approval and
refusal, argument passing to the real `osascript`, and each provider's tool
loop with recorded network responses. No test reads the real `chat.db` or sends
a message.

## Limitations

- AppleScript cannot send tapbacks, edits, unsends, or threaded replies, and
  cannot send attachments from Enigma.
- Sending requires a Mac signed in to Messages. A new recipient with no
  existing chat is sent over iMessage.
- Search decodes message bodies in Enigma rather than using an index, so very
  large histories are searched newest-first up to the scan limit.
- Local models need the `llama-server` runtime (Settings → Local Models →
  Install Local File Tools) and a model that supports tool calls.
- Answers from the OpenAI, Anthropic, and Gemini API routes appear when each
  tool round finishes rather than streaming token by token.
- Watching for new messages is not implemented.
