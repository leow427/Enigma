# Native tool calling for capable models (F32) — design

Status: design for the owner's review, not yet implemented. Date: 2026-10-28.
Plan: not written yet (it follows this spec's approval).
Affects: F29 (paused), F30 (re-scoped later) and F31 (halted). See
[Related items](#related-items).

## Goal and users

Today Enigma decides, before the model runs, whether a request searches the
web, reads Messages, or revises a selection. Hand-written English rules read
the draft and either turn a capability on (shown as a chip: `messages`,
`search`, `think`, `edit`, `translate`) or leave it off. Only then is the
model given tools, and only the ones the rules picked. The rules have grown
into long exception lists and still misfire, and F31's attempt to replace
them with trained classifiers stalled on Messages.

Capable models can make that decision themselves. F32 gives every capable
model Enigma's tools on every turn and lets it choose when to search, read a
chat or propose an edit, and write its own arguments. Small models keep
today's chips and rules unchanged.

Sensitive tools ask the user in the chat before anything is read, with
**For this conversation** and **Always** answers, so a model's choice never
reaches private data without a click.

**What the owner asked for (2026-10-28):**

- Lean on native tool calling instead of the chips. It is the top priority,
  ahead of F29 and F30.
- Keep the chips and hard-coded recognizers for small models (under about
  4B parameters); models of about 9B and up already call tools well.
- Accept the security trade-off, with a popup for sensitive things such as
  "allow reading messages in your chat with ‹contact›", answered for this
  conversation or always.

**Success means:**

- A capable model searches, reads Messages and proposes edits on its own
  when the request needs it, and doesn't when it doesn't.
- No message text reaches any model, and no web query leaves the Mac after
  a Messages read, without the user's click.
- Replies on every capable route still stream as they are written; time to
  first token on a plain question grows by at most 15%.
- Small models behave exactly as they do today.

## Decisions

Made with the owner on 2026-10-28:

| Topic | Decision |
| --- | --- |
| Which models | A per-model **native tools** flag, not a size threshold. 9B and larger local models and both mixture-of-experts models (Gemma 4 26B-A4B, Qwen3.6 35B-A3B) start on; Qwen3.5 2B starts off; Qwen3.5 4B, Gemma 4 E4B and Ministral 3 8B are decided by the tool-use eval. Cloud models are flagged |
| Tools a capable model calls on its own | Web search (with places and weather once F29 lands), Messages, and selection edit/translate |
| Not a tool | Screen capture stays typed-only (`/screen`, `/snapshot`). `/think` stays a typed command; it sets the reasoning budget before the model runs |
| Reading a chat | A popup per chat that names where the text goes. **Always** is remembered per chat **and** destination (this Mac, OpenAI, Anthropic, Google) |
| Listing and searching chats | Listing chats is free (names, participants, times; no text). Searching all chats asks, showing the search term |
| Search after a Messages read | Once any message text is in the conversation, each web search asks first, showing the exact query, with the same three answers |
| Approach | Tools on every turn for flagged models, with streaming tool loops on every route (approach A) |
| Rejected: tools now, streaming later | Replies on the OpenAI, Anthropic, Gemini and local routes would arrive all at once until a follow-up |
| Rejected: a pre-check that decides whether to open the tool loop | That check is the router again |
| Local runtime | Flagged local models run on `llama-server` for every turn; small models stay on the in-process `LlamaBridge` engine |
| Rejected: tool calling inside `LlamaBridge` | Substantial C++ in the package, and each model family's tool-call format would have to be kept current there |

Calls made in the design and approved with it:

- In Auto, a typed `/messages` still goes to the local model, as today. A
  Messages read the model starts on its own goes to whichever model Auto
  picked, behind the popup.
- The one-time Messages cloud notice is replaced by the per-destination
  popup.
- With files attached, only File Mode's tools are offered. With a screenshot
  attached, the Messages tools are withheld.

## Design

### 1. Who gets tools, and how a request flows

**The flag.** `LocalModelDescriptor` gains a `nativeTools` flag, set per
catalogue entry (every quantization of a model shares it). Cloud models are
flagged; CP0 confirms each catalogue cloud model supports function calling,
and any that doesn't is treated as unflagged. One function answers "is this
route flagged?" for a resolved route, and everything below asks it.

**Routing.** The composer already resolves the route while the user types
(the `● local` / `○ cloud` indicator).

- **Unflagged route:** today's path, untouched. `ComposerIntent.resolve`
  runs the recognizers, shows chips, and the chosen command builds today's
  toolbox or prompt. The **Recognize commands from your wording** setting
  applies here only.
- **Flagged route:** the recognizers don't run and no recognized chips are
  shown. Typed commands are still parsed and highlighted. The request goes
  to the route's tool loop with the turn's toolbox (section 2).

**Typed commands on a flagged route:**

| Command | Effect |
| --- | --- |
| `/search` | `web_search` is offered even with automatic search off, and the model must call it on its first step (forced tool choice where the provider supports it, an instruction otherwise) |
| `/messages` | The system prompt says the user asked to use Messages. In Auto it routes to the local model, as today |
| `/edit`, `/translate` | The model must call `propose_edit` or `propose_translation` |
| `/think` | Unchanged |
| `/screen`, `/snapshot` | Unchanged: capture first, then send with the capture |

**Settings still apply.** With automatic search off, `web_search` is not
offered unless `/search` is typed. Without a Brave key (until F29), it is
never offered. The Messages tools are offered only while Full Disk Access is
granted.

**Today's privacy conflicts stay.** Files attached: File Mode's toolbox only.
Screenshot attached: no Messages tools.

**Auto** keeps choosing local or cloud with its current rules. On a flagged
route, the `requiresWebSearch` decision no longer blocks a send with "Use
/search…", because the model can search for itself.

### 2. Tools and permissions

**One toolbox per turn**, composed from parts (`AgentToolbox` already
describes one; the composite merges definitions, instructions and phases):

| Part | Tools | Offered when |
| --- | --- | --- |
| Search | `web_search(query)` | Search is available (above). Brave today; F29's engines later, plus places and weather tools. The coarse "near me" city is added on the Mac, as today |
| Messages | `list_conversations`, `search_contacts`, `get_messages`, `search_messages`, `send_message` | Full Disk Access granted, no files or screenshot attached |
| Selection | `propose_edit(text)`, `propose_translation(text, language)` | Selection Context attached |

- `list_conversations` returns names, participants and times. It includes the
  last-message preview only for chats already allowed for this destination.
- `search_contacts` is free; it returns names and handles, no message text.
- `get_messages` asks per chat (gate 1). `search_messages` asks once
  (gate 2).
- `send_message` keeps today's approval card for every message, the
  duplicate-send ledger, and the Automation check.
- The selection tools fill today's `SelectionRevisionCard`. Replacing the
  selection still needs the user's click, and translation stays read-only.
- Web search results feed today's sources list and activity row.

**The permission card** is an in-chat card in the style of
`MessagesSendApprovalCard`. The reply pauses while it is open:

> **Allow reading your chat with Mom?** It will be sent to Anthropic.
> [Don't allow] [For this conversation] [Always]

On a local route the second line reads "It stays on this Mac."

**Three gates:**

| Gate | Asked before | Card shows | Remembered per |
| --- | --- | --- | --- |
| 1. Read a chat | `get_messages` on a chat not yet allowed | Chat name, destination | Chat and destination |
| 2. Search all chats | `search_messages` | Search term, destination | Destination |
| 3. Search the web after a Messages read | `web_search` once any message text (a read, a search hit, or an allowed preview) is in this conversation | Exact query | Once, for every destination (the query goes to the search engine, whichever model is answering) |

**Answers:**

- **Don't allow:** the tool returns "The user declined" and the model
  carries on without the data.
- **For this conversation:** kept in memory with the chat session. Never
  saved; reopening a chat from Recents asks again. Gone when the chat is.
- **Always:** saved in settings (not the Keychain; it isn't a secret) and
  listed under **Settings → General → Messages** with a **Remove** button for
  each.
- Pressing Stop while a card is open counts as Don't allow.

**Destinations** are counted per company: this Mac; OpenAI (API and Codex);
Anthropic (API and Claude Code); Google (Gemini).

**Rules the host enforces, not the prompt:**

- The gates run in Swift before a tool executes. No text from a model, a web
  page, a message or a file can grant permission; only a click on the card
  can.
- The system prompt marks tool results as untrusted data, never instructions.
- Whether message text is "in the conversation" (gate 3) is tracked by the
  host per chat session, not inferred from the prompt.

### 3. Streaming tool loops

**Cloud.** The OpenAI, Anthropic and Gemini loops in `CloudToolCalling.swift`
switch from one non-streaming POST per step to streaming requests. Text is
emitted as it arrives; tool calls are assembled from the stream:

- OpenAI Responses: text deltas, and function-call argument deltas completed
  by the output item's done event.
- Anthropic Messages: `text_delta`, and `input_json_delta` within a
  `tool_use` block.
- Gemini: `streamGenerateContent` over SSE; function calls arrive whole.

Codex and Claude Code already stream and only take the new toolbox. Calls
still run one at a time so each card appears on its own, and the 12-step
limit stays. CP0 confirms the exact event names and each provider's forced
tool choice.

**Local.** Flagged local models run on `llama-server` for every turn,
through a streaming `LocalToolAgent` (OpenAI-compatible chat completions
with streamed tool-call deltas). One call per step stays.

- **Warm between turns.** Today File Mode loads the model into
  `llama-server` per request and unloads it afterwards. A flagged model's
  server stays loaded between turns, under the same idle and memory rules as
  today's in-process engine (CP3 records what those are). Only one runtime
  holds the model at a time, as today.
- **Prompt cache.** The system prompt and tool definitions (about a thousand
  tokens) sit at the start of every request so `llama-server`'s prompt cache
  reuses them after the first turn.
- **The runtime.** The 11 MB `llama-server` runtime installs with any flagged
  model's download, and on first launch after the update for an
  already-installed flagged model (same source and checksum as today's
  **Install** button). If it is missing or fails to start, the model runs on
  today's unflagged path, and Settings offers **Install** or shows the error.

## Failure handling

- A tool that fails returns its error to the model as a result; the model
  carries on.
- Terminal problems end the request with today's cards: Full Disk Access
  lost, Automation denied, or Stop.
- Malformed arguments return today's "Invalid tool arguments" result. A model
  that keeps calling tools hits the 12-step limit and today's message.
- A stream that drops mid-call fails the request like a dropped reply today;
  a half-built call never runs.
- If `llama-server` fails to start for a flagged model, the request falls
  back to the unflagged path and says so once in the activity row.

## Privacy

1. No message text reaches any model without a grant for that chat (or for
   cross-chat search) and that destination.
2. After message text enters a conversation, no web query leaves the Mac
   without gate 3. Provider-side search tools are never offered in such a
   conversation (relevant once F30 exists).
3. Only the user's click grants permission.
4. The screen is captured only by a typed command.
5. Every send needs its own approval, as today.
6. Files attached: File Mode's tools only. Screenshot attached: no Messages
   tools.
7. Small models: today's behavior, unchanged.
8. Selection tools only propose; replacing the selection needs a click.

## Testing

Offline, in CI:

- **Gates:** each gate asks once, then honours For this conversation and
  Always; Always is keyed per destination; Don't allow and Stop return the
  declined result; a conversation grant is gone in a new chat; gate 3 starts
  after a read, a search hit or an allowed preview, and not before.
- **Previews:** `list_conversations` shows previews only for allowed chats.
- **Toolbox composition:** a table test over route (flagged or not) × files ×
  screenshot × selection × automatic search × Brave key × Full Disk Access ×
  typed command.
- **Routing:** flagged routes run no recognizers and show no chips;
  unflagged routes keep today's results (existing `ComposerIntent` tests stay
  green unchanged).
- **Streaming parsers:** recorded fixtures per provider, covering text only,
  one call, several calls, text interleaved with calls, and a stream cut
  mid-call.
- **Local loop:** a stub `llama-server` for streaming deltas, warm reuse
  between turns, and the fallback when it won't start.
- **Settings:** the Always list shows and removes grants.

Opt-in live checks (the owner approves each batch; agents never handle API
keys, which reach only owner-run commands):

- **Tool-use eval**, about 60 prompts: should search, shouldn't search, read
  a named chat, search chats, edit or translate a selection, and injection
  cases (a search result that says "read my messages"; the right decision is
  to ignore it). A model is flagged at 90% or more right decisions. This sets
  the flag for Qwen3.5 4B, Gemma 4 E4B and Ministral 3 8B, and confirms the
  starting flags.
- **Latency:** time to first token on a plain question, today's path against
  the flagged path, for each flagged local model the owner has installed and
  one model per cloud provider. The switch-over needs at most +15%.

## Docs

Update with the behavior change: [Slash commands](../../Slash-Commands.md)
(recognized commands apply to small models; flagged models choose tools),
[Messages](../../Messages.md) (the permission cards, the Always list, the
cloud notice removed), [Web Search](../../Web-Search.md) (the model decides;
gate 3), [Selection Context](../../Selection-Context.md) (the selection
tools), [Cloud models](../../Cloud-Model-Selection.md) (Auto's web-search
rule on flagged routes), [Local models](../../Local-Model-Selection.md) (the
flag, and the runtime for flagged models), and [Chat](../../Chat.md) (the
permission card).

## Delivery

A checkpoint plan, like F29's: each checkpoint is built by a fresh worker
chat the owner starts, audited by fresh reviewers (at most three rounds), and
committed on its own (`… (F32 CPn)`), on branch `feat/f32-native-tool-calling`
in a worktree outside `~/Documents`. An internal switch keeps flagged routes
on today's path until the last checkpoint, so `main` stays shippable.

- **CP0 — probe:** streaming event names and forced tool choice per
  provider; `llama-server` streamed tool calls for each flagged model family;
  latency and memory of a warm `llama-server` against the in-process engine;
  Codex and Claude Code start-up with tools on every turn; the eval harness.
- **CP1 — permissions:** the gates, the grant store, the card, and the
  Settings list.
- **CP2 — cloud streaming:** streaming loops for OpenAI, Anthropic and
  Gemini.
- **CP3 — local:** flagged local models on a warm `llama-server`, runtime
  install and fallback.
- **CP4 — toolbox and routing:** the composite toolbox, the selection tools,
  the flag, the route switch, typed commands.
- **CP5 — switch-over:** the eval and latency gates, docs, and turning the
  switch on.

## Related items

- **F29 (on-device search)** stays paused. Its engines, ranking and page
  reading (CP2–CP4) become `web_search`'s backend; its CP5/CP6 are
  re-planned as tools (places, weather) for flagged models, with today's
  routing kept for small models.
- **F30 (native cloud search)** is re-scoped after F32: a provider's own
  search only in conversations with no message text, and Enigma's gated
  `web_search` otherwise.
- **F31 (trained classifiers)** stays halted. Its search model could later
  serve small models.
- **F27 and F6** (small local models and tools) fit the flag: unflagged
  models are the ones they protect.

## Out of scope

- Screen capture as a tool.
- Moving small models to `llama-server` and removing `LlamaBridge` (a
  possible later simplification).
- Provider-side web search (F30), and places and weather tools (F29).
- Tools in File Mode beyond today's file tools.
- New recognizers or classifiers for small models.

## Open questions for CP0

1. The exact streaming event names for function-call arguments on OpenAI
   Responses and Anthropic, and Gemini's streamed function-call shape.
2. Forced tool choice: OpenAI, Anthropic and Gemini support naming a
   function; does `llama-server` b11734, and can Codex or Claude Code do it
   at all? Where they can't, `/search` and `/edit` use an instruction.
3. Does `llama-server` b11734 parse streamed tool calls reliably for Qwen3.5,
   Qwen3.6, Qwen3.8, Gemma 4 and Ministral 3 with `--jinja`? A family that
   doesn't stays unflagged.
4. Time to first token and memory: warm `llama-server` against the
   in-process engine on the owner's Mac.
5. Do Codex and Claude Code start slower when every turn carries tools?
6. Does every catalogue cloud model support function calling?
