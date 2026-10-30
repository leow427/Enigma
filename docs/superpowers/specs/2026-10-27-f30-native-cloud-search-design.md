# Native web search for cloud models (F30) — design

Status: revised design for owner approval, 2026-10-29. It replaces the design
approved on 2026-10-27, which predated native tool calling (F32).
Plan: [2026-10-27-f30-native-cloud-search.md](../plans/2026-10-27-f30-native-cloud-search.md).
Depends on: F32 (native tool calling), on `main` since 2026-10-29. It no
longer depends on F29, and runs before it (owner, 2026-10-29).
Amended 2026-10-29 after CP0 (owner): Anthropic uses
`response_inclusion: "full"`, and a provider's search may get the user's
approximate location once the user allows it for that provider
([section 2a](#2a-location-with-the-users-consent)).
Amended 2026-10-29 after CP1 (owner): the API-key routes (OpenAI and
Anthropic) are deferred; F30 ships on ChatGPT (Codex) and Claude Code.
~~A typed `/messages` turn never gets provider search.~~
Amended 2026-10-29 during CP6's in-app audit (owner), replacing "no provider
search in a chat that holds message text" and the `/messages` exclusion: in a
chat that holds message text, and on a typed `/messages` turn, the provider's
search runs once the user allows it on a card for that provider; declined, the
turn doesn't search at all. The restart stays, and its second run asks the same
card ([section 2](#2-keeping-message-text-out-of-provider-search)). Enigma's
own search card now says the query goes to Brave.

## Goal and users

Since F32, every flagged cloud model gets Enigma's `web_search` tool and
decides for itself when to search. That tool runs on Brave, so it's offered
only to people who saved a Brave key. Everyone else's cloud model can't
search at all.

Cloud providers have their own search, and it's often better: bigger
indexes, pages read on the provider's servers, and follow-up searches the
model chooses. F30 offers the provider's own search tool in place of
Enigma's `web_search` on ChatGPT (Codex) and Claude Code, the runtimes
Enigma's users are expected to use, whenever privacy allows. Enigma's
`web_search` stays for everything else: Gemini, the OpenAI and Anthropic
API-key routes (deferred, see [Decisions](#decisions)), and the fallback.
In a chat that holds message text, the provider's search runs only after the
user allows it on a card (amended 2026-10-29).

**What the owner asked for:**

- "I dont mind allowing the cloud models to use their own search"
  (2026-10-26).
- Quality first: good sources, no ads, no obviously bad sites.
- Seamless: nothing to set up.
- Decisions made on 2026-10-27, still standing:
  - Gemini keeps Enigma's search;
  - ~~location is never sent to a provider's search~~, replaced on
    2026-10-29: the approximate location goes to a provider's search only
    after the user allows it for that provider;
  - Codex searches the live web.
- Decisions made on 2026-10-28 and 2026-10-29:
  - ~~a provider's own search only in conversations with no message text,
    Enigma's gated `web_search` otherwise (F32 spec, Related items)~~,
    replaced on 2026-10-29: in a chat with message text, the provider's
    search runs after the user allows it on a per-provider card;
  - F30 runs before F29.
- Built in checkpoints like F29 and F32.

**Success means:**

- **Search without a key.** On those two providers, a flagged cloud model
  can search with nothing set up, Brave key or not. Its sources are shown
  and saved as today.
- **Message text stays put.** No provider search runs in a chat that holds
  message text unless the user allowed it on that provider's card, and no
  provider search request carries message text the user hasn't allowed this
  way (amended 2026-10-29).
- **Silent fallback.** When provider search isn't available (the model, an
  organization policy, or the plan), the request carries on with Enigma's
  `web_search`, or without search if that isn't available either. Later
  requests skip the failed attempt.
- **No change elsewhere.** Gemini, unflagged models, small local models,
  File Mode and screenshot turns behave as today.
- **Each provider passes the quality check** in [Testing](#testing) before
  it's turned on in the merged branch.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Approach | Offer each provider's own search tool inside F32's streaming tool loop, **instead of** Enigma's `web_search` | One search tool per request keeps the model's choice simple. The other F32 tools (Messages, selection) stay offered beside it. |
| Which turns | Flagged cloud turns that would get the search part under F32's rules: automatic search on, or `/search` typed. A Brave key is no longer needed for provider search | The automatic-search switch keeps its meaning. |
| Providers | ChatGPT (Codex) and Claude Code. OpenAI and Anthropic (API key) are deferred (owner, 2026-10-29): they keep Enigma's `web_search`, and their sections in §3 stay as the design for later | These have a search tool Enigma can turn on per request. The app's users are expected to use the Codex and Claude Code runtimes, and the owner has no API key to check the API routes live. |
| Gemini | Enigma's `web_search` (owner, 2026-10-27) | Google's terms require showing Google's "Search suggestions" chip, which is Google's own HTML, with every grounded answer. That doesn't fit `docs/design/UI-Style.md`. |
| Unflagged cloud models | Unchanged: today's path | F30 builds on the tool loop. |
| Message text | In a chat that holds message text (`ChatSession.holdsMessageText`), or on a typed `/messages` turn, only after the user allows it on a per-provider card (owner, 2026-10-29; it was "never"). Declined: no search. If message text would enter a provider-search request the user hasn't allowed this way, that request stops and runs again, asking the card first | F32 privacy rule 2 wants a card before a query leaves once message text is in a chat. A provider's search runs on its servers, where Enigma can't show a card per query, so the card asks for the provider's search itself. |
| Location | Sent to a provider's search only after the user allows it on a card, per provider: Don't allow, For this conversation, or Always (owner, 2026-10-29, replacing "never"). City, region, country and time zone; never coordinates. Only for a question about places or weather near the user | Nearby questions need it, and the card tells the user exactly what goes where. A grant for one provider never covers another. |
| Selection attached | Provider search allowed | The provider already has the selection, and F32's `web_search` already lets the model put selection text in a query. |
| Codex search mode | `live` (owner, 2026-10-27) | People search for fresh information, and the cached index can be days old. |
| Anthropic tool | `web_search_20260318` with `response_inclusion: "full"` on models from Claude 4.6 on, and `web_search_20250305` on older ones | The newer tool filters results with code before they reach the model: better accuracy, fewer tokens. `full` keeps the search blocks, so Enigma sees each search and its results (owner, 2026-10-29, after CP0 found `excluded` hides them). |
| OpenAI tool | `web_search`, with `include: ["web_search_call.action.sources"]` | `web_search_preview` is the legacy tool. |
| Claude Code tool | `WebSearch` only; `WebFetch` stays off | `WebFetch` downloads pages from the user's Mac, which can reach the local network. |
| Typed `/search` | The provider's search tool is forced where the provider allows it, and asked for in words otherwise | The same rule F32 uses for `web_search`. |
| Searches per request | At most 5 | Bounds the cost per reply on API keys, roughly 5¢. |
| Sources shown | The pages the answer cites; when it cites none, the results the model saw. At most 8. | The list keeps today's size, and the providers require showing citations. |
| Fallback | Enigma's `web_search` when it's available, otherwise no search tool. Remembered per provider and model until the app quits | Seamless, and one failed attempt per session at most. |
| Blocked sites | None in F30. F29's "Never use this site" passes them on later: `blocked_domains` for Anthropic, a sentence in the instruction for the others | F29 runs after F30. |
| Settings | No new setting | Seamless. A switch to prefer Enigma's search can follow if people ask. |
| Delivery | Checkpoints, each built by a fresh worker and audited by fresh reviewers | Same process as F29 and F32. See [Delivery](#delivery). |

## Design

### 1. Which search tool a turn gets

F32 composes one toolbox per flagged turn (`NativeToolPlan.make`, then
`AssistantToolbox`). F30 decides which search the search part uses.

**`NativeToolPlan.Inputs` gains `providerSearch: Bool`,** true when all of
these hold:

- the route is a flagged cloud route whose provider is in
  `CloudProviderID.nativeWebSearchProviders` (empty until a checkpoint turns
  its provider on; never `.gemini`);
- this provider and model aren't marked unavailable this run;
- the Messages tools haven't returned message text earlier in this reply,
  unless the user allowed the provider's search on the card below (see
  section 2).

*Amended 2026-10-29 (owner):* it no longer requires a chat without message
text, or no typed `/messages`. In those cases `submitNative` first asks
**Let ‹provider› search the web in this chat?** *This chat includes text from
your messages. ‹provider›'s web search runs its own queries on ‹company›'s
servers, and Enigma can't check each one.* (Don't allow, For this
conversation, Always), keyed by `CloudProviderID` like the location card
(`ToolPermission.providerSearchAfterMessages`). Allowed: provider search, and a
Messages read in that request is delivered with no restart. Declined: the turn
has no search part (`NativeToolPlan.withoutSearch()`), not even Enigma's.

**The search part** is offered when automatic search is on or `/search` is
typed, and then either:

- `providerSearch` is true: the plan's `search` becomes `.provider`, with
  no Brave key needed; or
- a Brave key is saved: `.enigma`, F32's `WebSearchTool`, as today.

`NativeToolPart.search` becomes `search(SearchBackend)`, with
`SearchBackend` `.enigma` or `.provider`. A typed `/search` sets
`requiredTool` to `web_search` for both: on the provider routes that name is
the provider's tool (OpenAI's tool type and Anthropic's tool name are both
`web_search`; Codex and Claude Code get the instruction).

**`ChatRequest` gains `providerSearch: ProviderSearch?`**, set by
`submitNative` when the plan's search is `.provider`:

```swift
struct ProviderSearch: Sendable, Equatable {
  /// F29's blocked sites, most recently blocked first. Empty until F29.
  var blockedDomains: [String] = []
}
```

When it's set, the provider's tool loop adds its search tool and the search
instruction (section 4) to the request, and the toolbox has no `web_search`
function. `ProviderSearchPart`, an `AgentToolbox` with instructions and no
definitions, carries the instruction into `AssistantToolbox`, so the system
prompt stays assembled in one place.

**What the other tools do on a provider-search turn:** Messages and
selection tools are offered exactly as F32 offers them. The model can read a
chat behind gate 1 or search chats behind gate 2; section 2 says what
happens next.

### 2. Keeping message text out of provider search

F32 tracks message text per chat: the gated `MessagesTools` calls
`didReturnMessageText()` the moment a tool returns message text (a read, a
search hit or an allowed preview), and `SavingMessagesGate` marks the chat.

**On a provider-search request the user hasn't allowed, the result is never
delivered.** When a Messages tool is about to return message text into a
request whose `providerSearch` is set, and the user hasn't allowed that
provider's search for this chat (no card this turn, no grant; amended
2026-10-29):

1. the tool's result is held back: it never reaches the provider;
2. the chat is marked, as today;
3. the request stops (`ProviderSearchRestart`, a cancellation the loop
   reports as a restart, not as Stop);
4. `submitNative` runs the same turn again from the start, with the plan
   made again. The chat now holds message text, so it asks section 1's
   provider-search card first (amended 2026-10-29; it was `.enigma` behind
   gate 3): allowed, the second run has provider search and its read is
   delivered; declined, it has no search.
   The read's grant still applies (For this conversation or Always), so the
   model reads the chat again without a second card.

The reply on screen restarts too: text written before the restart is
cleared, and the sources found so far are dropped, since they belong to the
stopped request. A restart happens at most once per turn: the second run
either has the user's go-ahead for provider search, so its reads are
delivered, or has no search (amended 2026-10-29).

The check lives in the host, in the gate, not in the prompt: no model text
can skip it. It works the same on all four routes, because Enigma runs every
Messages tool itself: as a function call on the API routes, a dynamic tool
on Codex, and an MCP tool on Claude Code.

**Why a restart and not a swap.** On the API routes the next step could drop
the search tool instead. On Codex and Claude Code the tools are fixed when
the thread or process starts, so only a new request can drop them. One rule
for every route is simpler to test.

### 2a. Location, with the user's consent

Owner, 2026-10-29. This replaces the 2026-10-27 rule that location never
goes to a provider's search.

**When Enigma asks.** All of these hold:

- the turn's search is `.provider` (section 1);
- the current question is about places or weather near the user, by
  `LocationIntent.needsLocation` (the user's own words only, never quoted or
  attached text, and never when the question names a place or says not to
  use the location);
- Settings → General → Location → "Use location for nearby questions" is on;
- this provider has no grant yet for this chat (For this conversation) or
  for good (Always).

Enigma first finds the area with `LocationService`, on the Mac, as today.
If location is off, denied or unavailable, there's no card and no location:
the instruction says to ask which city the user means.

**The card** appears before the request is sent, in F32's permission card
(`ToolPermissionCard`), with its three buttons:

> **Share your location with ‹provider›?**
> ‹provider›'s web search will use ‹City, Region, Country› to find nearby
> results. Enigma never sends your exact position.
>
> Don't allow · For this conversation · Always

‹provider› is the route's provider name as Enigma shows it: OpenAI,
ChatGPT, Anthropic or Claude Code.

**Per provider.** The grant is keyed by `CloudProviderID`, not by F32's
`ToolDestination` (which joins ChatGPT with the OpenAI API, and Claude Code
with the Anthropic API). Allowing ChatGPT never allows the OpenAI API, and
the other way round. "For this conversation" lasts as F32's conversation
grants do, until the chat is deleted or the app quits; "Always" is saved
with F32's Always grants and listed, and removable, in Settings.

**What's sent.** With a grant, `ProviderSearch` carries
`location: ProviderSearchLocation?`: city, region, ISO 3166-1 alpha-2
country code and the Mac's IANA time zone. A part the geocoder didn't give
is left out; coordinates never leave the Mac. It goes with this turn's
requests only, and is looked up again for the next nearby question.

| Route | How |
| --- | --- |
| OpenAI | `user_location: {"type": "approximate", city, region, country, timezone}` on the `web_search` tool |
| Anthropic | `user_location` with the same fields on the `web_search` tool |
| ChatGPT (Codex) | `config.tools.web_search.location` (`{city, region, country, timezone}`) in `thread/start`; CP4 confirms the key |
| Claude Code | No location field: the instruction's near-me clause names the area, so it reaches Anthropic in the system prompt |

**Don't allow** sends nothing; the instruction says to ask which city they
mean, and the card comes back for the next nearby question in this chat.

**The instruction's near-me clause** (section 4) becomes, with a location:
"The user's approximate location is ‹City, Region, Country›; your web
search tool uses it for places and weather near them." Without one, it
stays "ask which city they mean".

**Not changed.** Enigma's own `web_search` keeps today's location handling;
the restart's second run keeps the location only if it still has provider
search; Gemini,
File Mode and screenshot turns are unchanged. Nothing about the location is
logged or saved, except the grant itself.

### 3. Providers

Each provider's client adds its search tool to the requests F32's tool loop
already builds, and reports what happens through the existing `.activity`
events:

- `.phase(.searching)` when a search starts;
- `.sourcesDiscovered` as results arrive, which moves the panel to
  "Reading sources (n)…";
- `.sourcesSelected` before `.completed`, with section 5's selection.

`submitNative` already merges the sources of every search in a reply onto
it (F32 CP4). Provider sources join the same list.

#### OpenAI (API key): `OpenAIResponsesClient` (deferred)

Deferred (owner, 2026-10-29): kept as the design for later. Until then the
OpenAI API route keeps Enigma's `web_search`.

**The request.** With `providerSearch` set, each step's body adds:

| Field | Value |
| --- | --- |
| `tools` | F32's function tools, plus `{"type": "web_search"}`: default context size, no `filters`, and `user_location` only as section 2a allows (`{"type": "approximate", "city", "region", "country", "timezone"}`); otherwise none |
| `include` | `["web_search_call.action.sources"]` |
| `max_tool_calls` | `NativeWebSearch.maximumSearches`, if CP0 confirms it counts only built-in tool calls; otherwise the instruction's limit alone |
| `tool_choice` | `{"type": "web_search"}` on step 1 when `/search` is typed, if CP0 confirms it; otherwise F32's instruction |

`store: false` stays. Each step's `web_search_call` and `message` items are
replayed in the next step's `input`, as F32's assembler replays function
calls; CP0 confirms the shape `store: false` accepts.

**The stream.** `OpenAIToolStreamAssembler` gains:

| Event | Action |
| --- | --- |
| `response.output_item.added`, item `web_search_call` | `.phase(.searching)` |
| `response.output_item.done`, item `web_search_call` | `action.sources[].url` are discovered sources. They have no title, so the site name is used. |
| `response.output_item.done`, item `message` | Each `output_text` annotation of type `url_citation` (url, title) is a cited source |

**Inline citations.** OpenAI requires them to be "clearly visible and
clickable". They arrive as Markdown links in the text, which Enigma's
renderer makes clickable; CP0 confirms. If they aren't in the text, CP2
appends them at the end of the reply as `[site](url)`.

**Unavailable.** A 400 for a request with `providerSearch` set, whose error
`param` starts with `tools` or whose message mentions `web_search`, becomes
`CloudProviderError.webSearchUnavailable(.openAI)`. CP0 records the bodies.

#### Anthropic (API key): `AnthropicMessagesClient` (deferred)

Deferred (owner, 2026-10-29): kept as the design for later. Until then the
Anthropic API route keeps Enigma's `web_search`.

**The tool** comes from `AnthropicMessagesClient.webSearchTool(modelID:blockedDomains:)`:

- **From Claude 4.6 on:** models in a reviewed prefix list get
  `web_search_20260318` with `max_uses` 5 and
  `response_inclusion: "full"`. The list covers `claude-opus-4-6`, 4-7
  and 4-8, `claude-sonnet-4-6`, `claude-opus-5`, `claude-sonnet-5`,
  `claude-fable-5` and `claude-haiku-5-5`; prefixes cover point releases.
  CP0 confirms it.
- **Older models** get `web_search_20250305` with `max_uses` 5.
- **`blocked_domains`** is left out while the list is empty, which it is
  until F29.

It joins F32's client tools in each step's `tools`. A typed `/search` forces
it with `tool_choice: {"type": "tool", "name": "web_search"}` where CP0
shows that works, and F32's instruction otherwise (never under `/think`,
which can't force a tool).

**The stream.** `AnthropicToolStreamAssembler` gains:

| Event | Action |
| --- | --- |
| `content_block_start`, block `server_tool_use` named `web_search` | `.phase(.searching)` |
| `content_block_start`, block `web_search_tool_result` whose `content` is a list | Its `web_search_result` entries (url, title) are discovered sources |
| `content_block_start`, block `web_search_tool_result` whose `content` is an object | A search error such as `max_uses_exceeded`; the model carries on |
| `content_block_delta`, `citations_delta` with a `web_search_result_location` | A cited source |
| `message_delta` with `stop_reason: "pause_turn"` | Continue (below) |

**Replaying server blocks.** The next step must send the assistant message
back with every block unchanged, server-tool and code-execution blocks
included (their encrypted content too). The assembler keeps each
`content_block_start` block as JSON and applies the `text_delta`,
`citations_delta`, `input_json_delta`, `thinking_delta` and
`signature_delta` deltas to it.

**`pause_turn`.** The API can pause a long search turn. The loop sends the
same request with the rebuilt assistant message added, and keeps streaming
into the same reply, at most 3 times per step. A pause doesn't count toward
F32's 12-step limit. After 3, the reply ends with the text so far.

**Unavailable.** A 400 `invalid_request_error` whose message mentions web
search (an organization that turned it off, or a model without it) becomes
`.webSearchUnavailable(.anthropic)`. CP0 records the bodies.

**Output budget.** CP0 measures whether search blocks count against
`max_tokens`. If they do, provider-search requests add a fixed margin, set
in CP3 from the measurement.

#### ChatGPT (Codex): `CodexSubscriptionClient` and `CodexToolMode`

**The setting.** The app server starts with `-c web_search="disabled"`
(`CodexAppServer.arguments`). A provider-search thread asks for
`{"web_search": "live"}` in `thread/start`'s `config`, beside F32's
`dynamicTools` (`CodexToolMode.threadParameters`). If the thread setting
doesn't override the launch setting (CP0 question 3), CP4 uses the first
option that works:

1. drop the launch argument and send `web_search` on every thread,
   `"disabled"` or `"live"`;
2. run a second app server, launched with `web_search="live"`, for
   provider-search threads only.

**Policy.** A workspace can limit search modes (`allowedWebSearchModes`).
If `live` isn't allowed, `cached` is used when it is. If neither is, the
client throws `.webSearchUnavailable(.chatGPT)` before starting the turn.

**The turn** stays as F32 runs it: read-only sandbox, approvals declined,
an empty workspace. Web search is a tool OpenAI runs, so it needs no local
network access.

**Events** (CP0 checks them against the pinned Codex):

| Notification | Action |
| --- | --- |
| `item/started`, item type `webSearch` | `.phase(.searching)` |
| `item/completed`, `webSearch`, action `openPage` with a `url` | A discovered source |
| `item/completed`, `webSearch`, with `results` | Each object with a string `url` (and `title` if present) is a discovered source |

**Sources.** Codex reports no citations, so the cited sources are the links
in the final answer (`NativeWebSearch.links(in:)`).

**Unavailable.** A JSON-RPC error from `thread/start` when `config` sets
`web_search`, or a turn that fails before any text with an error about web
search. CP0 records both.

#### Claude Code: `ClaudeCodeSubscriptionClient` and `ClaudeCodeToolMode`

**Arguments.** F32 runs Claude Code with `--tools ""`, Enigma's tools on an
SDK MCP server, and `--allowedTools` listing them. With `providerSearch`
set, `--tools WebSearch` replaces `--tools ""` and `WebSearch` joins
`--allowedTools`. These stay unchanged: `--safe-mode`,
`--strict-mcp-config`, `--disable-slash-commands`, the empty workspace and
the stripped environment.

**Parser.** `ClaudeCodeStreamParser.Event` gains:

| Event | From | Action |
| --- | --- | --- |
| `.toolsListed([String])` | The `system` `init` message | If `WebSearch` is missing (a policy withheld it), the client stops the process and throws `.webSearchUnavailable(.claudeCode)` |
| `.searchStarted` | A `tool_use` block named `WebSearch` | `.phase(.searching)` |
| `.searchResults([WebSearchSource])` | The `user` message's `tool_use_result.results[].content[]` (`{title, url}`) | Discovered sources; entries of another shape are skipped |

**Sources.** The cited sources are the links in the final answer.

#### Gemini

Unchanged: Enigma's `web_search` when a Brave key is saved (and F29's
search later), as F32 offers it.

### 4. The search instruction

`ProviderSearchPart.instructions` replaces `WebSearchTool`'s on
provider-search turns. It keeps F32's date line and its guidance, which the
F32 eval measured, and adds the provider rules:

> Today is ‹weekday, d MMMM yyyy›. You can search the web with your web
> search tool. Use it for facts that change or that you may not know: news,
> prices, schedules, weather, recent events, and specific pages. You can't
> see live information yourself, so when a question depends on it, search
> instead of saying you can't look it up or asking for the date. Don't
> search for things you already know well, for the user's own data, or to
> answer from Messages or an attached selection. Search at most 5 times.
> Never put personal details, credentials, file contents, or text from
> messages into a search query. ‹Near-me clause›. Link the pages you rely
> on.

The date is formatted as `WebSearchTool` does it. The near-me clause is
section 2a's: with a location allowed for this provider, "The user's
approximate location is ‹City, Region, Country›; your web search tool uses
it for places and weather near them"; otherwise "You don't know where the
user is: for places or weather near them, ask which city they mean". F29
may later add its own places and weather tools.

**Where it goes:** F32's system prompt on the API routes; Codex's
`developerInstructions` and Claude Code's `--system-prompt` through
`CodexToolMode` and `ClaudeCodeToolMode`. Their line saying the model has
only Enigma's tools gains "and web search" (Codex) or "and WebSearch"
(Claude Code).

### 5. Sources and citations

`NativeWebSearch.selectSources(cited:linked:discovered:)`:

1. Start with the cited sources, in the order first cited.
2. Add the answer's links: for Codex and Claude Code these are their
   citations; for OpenAI and Anthropic, links not already cited.
3. If steps 1 and 2 found nothing, use the discovered sources, in arrival
   order.
4. Tidy: keep only `isSafeWebLink` URLs, drop duplicates (URLs compared
   without their fragment), use the site name for a missing title, and cap
   at 8.

**Display.** The sources list shows each selected source with its title and
link, which meets Anthropic's rule that "citations must be included to the
original source". OpenAI's inline links stay in the text. The reply's footer
says "web search" for provider search, and keeps "brave search" for Brave.

**Saving.** As `WebSearchSource` (title and URL) in `searchSources`.
Unchanged format, so older chats load as before.

### 6. Architecture summary

**New file `Enigma/Cloud/NativeWebSearch.swift`:**

| Member | Job |
| --- | --- |
| `NativeWebSearch.maximumSearches` | 5 |
| `ProviderSearch`, `SearchBackend` | Section 1's types |
| `ProviderSearchPart` | The instruction (section 4) as an `AgentToolbox` part with no definitions |
| `NativeWebSearch.isAllowed(provider:modelID:enabledProviders:availability:)` | Section 1's rule, a pure function (no message-text check since the 2026-10-29 amendment; `submitNative` asks the card) |
| `NativeWebSearch.selectSources(cited:linked:discovered:)` | Section 5 |
| `NativeWebSearch.links(in:)` | Markdown links and bare `http`/`https` URLs in an answer, in order |
| `NativeWebSearchAvailability` | `markUnavailable(_:modelID:)` and `isAvailable(_:modelID:)`; held by `LocalChatViewModel`, never saved |
| `NativeWebSearchSources` | One request's bookkeeping shared by the four clients: discovered and cited sources, the answer text, and the selection for `.sourcesSelected` |
| `ProviderSearchRestart` | The error section 2's gate raises to stop a request for a restart |

**Changed:**

- `CloudProviderID` gains `nativeWebSearchProviders` (the set turned on)
  and `supportsNativeWebSearch`. `LocalChatViewModel` takes the set as an
  initializer parameter, so tests can pin either backend.
- `CloudProviderError` gains `webSearchUnavailable(CloudProviderID)`. Every
  client throws it, so `submitNative` checks one error. Its message, "Web
  search isn't available for this model.", appears only in logs and tests.
- `NativeToolPlan`, `NativeToolPart`, `ChatRequest`, the four clients'
  tool-calling extensions in `CloudToolCalling.swift`, their assemblers in
  `CloudToolStreaming.swift`, `ClaudeCodeStreamParser`, and
  `SavingMessagesGate` and `submitNative` in `LocalChatViewModel.swift`.

**One request, step by step:**

1. `submitNative` makes the plan. With `providerSearch` true it sets
   `ChatRequest.providerSearch` and uses `ProviderSearchPart`.
2. The provider's loop streams as F32 does, with the search tool added.
3. **Unavailable before the reply starts** (before the first text or tool
   call): the pair is marked unavailable, and the same turn runs again with
   the plan made again (Enigma's `web_search` or no search), with no second
   `beginGeneration`. After the reply starts, an unavailable error is shown
   like any other failure.
4. **Message text** on the way into the request: section 2's restart.
5. **Save.** The reply's `searchSources` gets the selected sources, even if
   the stream failed after some text arrived.

## Failure handling

| Situation | Behavior |
| --- | --- |
| Provider search unavailable before the reply starts | This turn runs again with Enigma's `web_search` or without search. The pair is marked unavailable until the app quits. |
| A search fails inside the turn (rate limit, `max_uses_exceeded`) | The model answers with what it has. |
| The model doesn't search | The reply stands, with no sources. The eval measures how often. |
| Anthropic `pause_turn` | Up to 3 silent continuations per step |
| Message text about to enter the request | Section 2's restart, once per turn |
| A nearby question, location not yet allowed for this provider | Section 2a's card, before the request; Stop while it shows ends the turn |
| Location off, denied or unavailable, or the card declined | No location sent; the model asks which city |
| Offline, signed out, or missing key | Today's errors |
| An error after the reply starts | As today: partial text kept, the error shown, sources found so far saved |
| Stop | As today. Stop during a restart ends the turn. |

## Privacy

**Compared with Enigma's `web_search`:**

| | Enigma's `web_search` | Provider search |
| --- | --- | --- |
| Who runs the searches | Enigma, from the Mac (Brave now, F29 later) | The provider, from its servers |
| Who writes the queries | The model | The model |
| Who sees the queries | Brave (F29: the search sites) | The provider and its search backend |
| Who sees the IP address | Brave (F29: the search sites and pages read) | Only the provider, as for any cloud request |
| Location | The area, for "near me" queries | City, region, country and time zone, only after the user allows it for that provider (section 2a); never coordinates |
| After message text enters the chat | Every query asks first (gate 3), naming Brave | Only after the user allows the provider's search on its card, per provider (amended 2026-10-29) |

**Rules:**

1. *Amended 2026-10-29 (owner):* no provider search in a chat that holds
   message text unless the user allowed it on that provider's card, and no
   message text in a provider-search request the user hasn't allowed this
   way (section 2).
2. Location goes to a provider's search only after the user allows it on
   that provider's card, only for nearby questions, and never as
   coordinates (section 2a).
3. Nothing new is stored. Availability marks live in memory.
4. Logs name the provider and the event, never a query or a URL.
5. OpenAI keeps `store: false`. Claude Code keeps `WebFetch` off. Codex
   keeps its read-only sandbox.

## Testing

**Offline tests,** deterministic and run in CI. Fixtures are recorded in
CP0 and live in `EnigmaTests/Fixtures/CloudSearch/`, read through
`#filePath`. Account, organization, thread and request IDs are scrubbed.

| Test class | Covers |
| --- | --- |
| `NativeWebSearchTests` (new) | `isAllowed` for each provider and availability; Gemini never; `selectSources` order, deduplication, the cap, unsafe links, site-name titles; `links(in:)`; the instruction text |
| `NativeToolPlanTests` | The search part's backend across provider search, Brave key, automatic search and typed `/search` |
| `NativeToolRequestTests` | Section 2a: the card shows only for a nearby question on a provider-search turn; each answer; a grant for one provider doesn't cover another (ChatGPT vs OpenAI, Claude Code vs Anthropic); no card and no location when location is off or unavailable; `submitNative` sets `providerSearch`; the fallback runs once and is remembered; the restart: the held-back result never reaches the fake provider, the second run asks the provider-search card (allowed: provider search; declined: none), and it happens once; the provider-search card in a chat with message text and on a typed `/messages` turn, per provider, and Stop while it shows; sources saved from provider events |
| `CloudToolStreamingTests` | Per provider, recorded streams with search and function calls mixed: activity, sources, replay bodies (OpenAI items, Anthropic server blocks), `pause_turn` continuation and its cap, the unavailable mapping |
| `CodexSubscriptionTests`, `ClaudeCodeSubscriptionTests` | Thread parameters and arguments with search, with and without a location, events from fixtures, the policy and `init` checks |
| `RequestLifecycleTests` | Stop during a provider search and during a restart; a failure before and after the reply starts |

**Live checks,** on the owner's Mac, not in CI. `NativeWebSearchLiveTests`
skip unless `ENIGMA_NATIVE_SEARCH_LIVE` is set. ChatGPT and Claude Code use
the Mac's sign-ins. (The deferred API routes would read keys from
`TEST_RUNNER_ENIGMA_OPENAI_KEY` and `TEST_RUNNER_ENIGMA_ANTHROPIC_KEY`, F32's
`EnvironmentCredentials`, never through an agent.)

**Quality check (CP6), per route:**

- **Decisions:** F32's tool-use eval (`NativeToolsEvalTests`, 60 prompts)
  runs with provider search on. The route keeps F32's bar: 0.90 or more,
  with the search and none categories each at least what F32 measured
  minus one.
- **Answers:** 20 web questions (news, changing facts, docs, health and
  finance, reviews, encyclopedic), written in CP6 and kept as
  `scripts/web-search-queries.json` for F29 to extend. Each runs twice on the
  same model: provider search, and Enigma's `web_search` on Brave with the
  owner's key. `scripts/evaluate-native-search.py` (standard library only)
  asks a cloud model, through its CLI, for a blind side-by-side judgment of
  correctness, recency and sourcing.
- **The gate:** provider search stays on for a route only if the eval
  passes; it searched on 18 or more of the 20 questions; at least 2 sources
  were shown on 18 or more; no source fails `isSafeWebLink`; and the judge
  prefers provider search or calls a tie on 80% or more.
- **Cost:** plan usage on the ChatGPT and Claude subscriptions. The owner
  approves each run.

A route that fails is removed from `nativeWebSearchProviders` and keeps
Enigma's `web_search`. The owner decides what's next.

## Docs

- **`docs/Web-Search.md`** gains "Cloud models' own search": which routes,
  when (with a card once message text is in the chat), sources and fallback, the privacy table, costs
  (plan usage on the ChatGPT and Claude subscriptions; no Brave key), the
  location card (section 2a), and limitations.
  Its "On models that choose their own tools", "How it works" and "Tests"
  sections are updated.
- **Updated:** `docs/ChatGPT-Setup.md` (live web search on search turns),
  `docs/Claude-Code-Setup.md` (`WebSearch`), `docs/Cloud-Model-Selection.md`
  (which providers search natively; Gemini), `docs/Messages.md` (provider
  search asks first once message text is in a chat), `docs/Chat.md` (the
  restart), `docs/Testing.md` (live checks and the quality check).
- **Release notes:** cloud models can search without a Brave key.
- **The report:** CP6 adds `docs/history/<date>-native-search-evaluation.md`,
  with metrics and judge results only.

## Delivery

**Branch:** `feat/f30-native-cloud-search` from `main`, in a worktree
outside `~/Documents`. Each checkpoint follows F32's loop: the owner starts
a fresh worker chat; the worker builds it from its brief, starts fresh
reviewers (at most three rounds), fixes, verifies and commits
`… (F30 CPn)`. There is no coordinator.

| Checkpoint | Goal | Exit criteria |
| --- | --- | --- |
| CP0 Spike | Answer the open questions below with probes on the owner's accounts; record fixtures | A written answer per question; fixtures scrubbed and saved |
| CP1 Shared plumbing | `NativeWebSearch`, the plan's search backend, `ChatRequest.providerSearch`, availability and fallback, the restart, sources, the location card and per-provider grant (section 2a). `nativeWebSearchProviders` stays empty | Tests pass; no visible change |
| CP2 OpenAI | Deferred (owner, 2026-10-29) | — |
| CP3 Anthropic | Deferred (owner, 2026-10-29) | — |
| CP4 ChatGPT (Codex) | The thread setting, events, links, policy check, error mapping; turn on `.chatGPT` | Tests pass; the live check passes |
| CP5 Claude Code | Arguments, parser, `init` check; turn on `.claudeCode` | Tests pass; the live check passes |
| CP6 Quality check, docs and audit | The eval and comparison per route, the report, docs, release notes, `to-do.md`, a final check in the running app | The gate passes on each route that ships; docs match behavior |

The API-key checkpoints (CP2, CP3) are deferred: their briefs stay as the
design for later, built from CP0's documented shapes once the owner has a
key to check them live. CP4 follows CP1.

**Open questions for CP0:**

1. **OpenAI.** With `web_search` beside function tools on the default
   model: the streamed event order and item shapes, `action.sources`;
   whether `output_text` carries the links; whether `max_tool_calls` counts
   only built-in calls; whether `tool_choice: {"type": "web_search"}` works;
   which items `store: false` accepts back in `input`; the error body for a
   model without search.
2. **Anthropic.** With `web_search_20260318` beside client tools, streamed:
   the event order including code-execution blocks; what replaying a step
   needs; `pause_turn` in a tool loop; whether `tool_choice` can name the
   server tool; whether search blocks count against `max_tokens`; the error
   bodies when search is off or unsupported; which listed model prefixes
   accept the new tool; the `blocked_domains` limit.
3. **Codex.** Does `thread/start`'s `config.web_search` override the launch
   argument with `dynamicTools` present? The requirements method and
   `allowedWebSearchModes`; the `webSearch` items and their order; whether
   answers carry Markdown links; what a disallowed mode returns.
4. **Claude Code.** `--tools WebSearch` with the SDK MCP server: the `init`
   tools list, the search events, whether answers end with their own
   "Sources:" list, whether `tool_use_result.results` ever holds plain
   strings.
5. **The restart.** On each route, can Enigma hold back a tool result and
   end the request cleanly (Codex `turn/interrupt`, ending the Claude Code
   process, cancelling the API stream), with nothing delivered?
6. **Latency.** First token and total time with provider search and with
   Enigma's `web_search` on Brave, for 5 questions per route.

## Out of scope

- Gemini grounding with Google Search (decided against).
- Provider search for unflagged models, File Mode and screenshot turns.
- Page-fetching tools: Claude Code `WebFetch` and Anthropic `web_fetch`.
- A setting to prefer Enigma's search on cloud routes.
- Inline citation markers for Anthropic replies (F11).
- Showing the provider's queries in the activity panel.
- Places and weather (F29).
