# Native web search for cloud models (F30) — design

Status: approved design, not yet implemented. Date: 2026-10-27.
Plan: [2026-10-27-f30-native-cloud-search.md](../plans/2026-10-27-f30-native-cloud-search.md).
Depends on: F29 (on-device web search), merged to `main`.

## Goal and users

After F29, every route searches with Enigma's on-device search. Cloud
providers have their own search, and it is often better:

- bigger indexes;
- pages read on the provider's servers;
- the model choosing follow-up searches.

F30 lets OpenAI, Anthropic, ChatGPT (Codex) and Claude Code models use their
provider's own search when a request would search. F29's search stays as the
fallback, and still handles Gemini, places, weather, screen and selection
turns.

**What the owner asked for:**

- "I dont mind allowing the cloud models to use their own search"
  (2026-10-26).
- Quality first: good sources, no ads, no obviously bad sites.
- Seamless: nothing to set up.
- Decisions made on 2026-10-27:
  - Gemini keeps on-device search;
  - questions that need the user's location keep Enigma's own lookup;
  - Codex searches the live web.
- Built in checkpoints like F29 (2026-10-27).

**Success means:**

- **Provider search answers.** On those four providers, a request that
  searches today is answered with the provider's search. Its sources are
  shown and saved as today.
- **No setup.** It works with the key or sign-in the route already has.
- **Silent fallback.** When provider search isn't available (the model, an
  organization policy, or the plan), the request falls back to on-device
  search with no action from the user. Later requests in the session skip
  the failed attempt.
- **No change elsewhere.** Gemini, places, weather, screen and selection
  turns behave as with F29.
- **No location sent.** Enigma never sends location to a provider's search.
- **Each provider passes the quality check** in [Testing](#testing) before
  its search ships.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Approach | Each provider's own search tool, turned on per request | Providers keep improving their search, and Enigma maintains nothing but the wiring. |
| Which requests | Only those that search today: the search chip, `/search`, or automatic search (`shouldSearch` in `LocalChatViewModel`) | The search switch keeps its meaning, and costs stay predictable. Letting the model decide on every turn is F26. |
| Providers | OpenAI (API key), Anthropic (API key), ChatGPT (Codex) and Claude Code | These are the providers with a search tool Enigma can turn on per request. |
| Gemini | On-device search (owner, 2026-10-27) | Google's terms require showing Google's "Search suggestions" chip, which is Google's own HTML, with every grounded answer. That doesn't fit `docs/design/UI-Style.md`. |
| Places and weather | Enigma's own lookup: F29's places and weather routes (owner, 2026-10-27) | Provider search doesn't know where the user is. Sending the location would share it with the provider. |
| Screen and selection turns | On-device search in version 1 | Their queries follow B11's rules for what screen or selection text may reach a query. Provider search would let the model put that text into queries. |
| Codex search mode | `live` (owner, 2026-10-27) | People search for fresh information, and the cached index can be days old. |
| Anthropic tool | `web_search_20260318` with `response_inclusion: "excluded"` on models from Claude 4.6 on, and `web_search_20250305` on older models | The newer tool filters results with code before they reach the model (dynamic filtering): better accuracy, fewer tokens. Older models don't support it. |
| OpenAI tool | `web_search`, with `include: ["web_search_call.action.sources"]` | `web_search_preview` is the legacy tool. |
| Claude Code tool | `WebSearch` only; `WebFetch` stays off | `WebFetch` downloads pages from the user's Mac, which can reach the local network. Team plans can also withhold it. |
| Searches per request | At most 5 | Bounds the cost per question on API keys, roughly 5¢. |
| Sources shown | The pages the answer cites; when it cites none, the results the model saw. At most 8 (`WebSearchLimits.maximumSources`). | The list keeps today's size, and the providers require showing citations. |
| Fallback | On-device search, when provider search is unavailable before the reply starts. Remembered per provider and model until the app quits. | Seamless, and one failed attempt per session at most. |
| Blocked sites (F29's "Never use this site") | Sent as `blocked_domains` to Anthropic. For the other three, named in the search instruction, as a best effort. | OpenAI, Codex and Claude Code have no block list Enigma can set. |
| Settings | No new setting in version 1 | Seamless. A switch to prefer on-device search can follow if people ask. |
| Delivery | Checkpoints, each built by a fresh agent and audited by a fresh reviewer | The owner asked for the same process as F29. See [Delivery](#delivery). |

## Design

### 1. Architecture and data flow

**One request, step by step:**

1. **Decide.** `submitCloud` already decides whether to search. When it
   does, `NativeWebSearch.decide` picks provider search or on-device search
   (the rules below).
2. **On-device.** The existing `submitCloudWithSearch` path runs unchanged.
3. **Provider search.** A new `submitCloudWithNativeSearch` streams the
   request with `ChatRequest.webSearch` set:
   - no on-device search and no evidence block;
   - the provider's client turns on its search tool, adds the search
     instruction, and reports what happens through the `.activity` events
     that already exist.
4. **Accept.** The question appears at once as the pending message
   (`pendingUserMessage`), as on the search path. The user message and the
   reply are added to the chat at the provider's first event, a search or a
   token, and `onAccepted` runs then.
5. **Fall back.** If the provider throws
   `CloudProviderError.webSearchUnavailable` before that first event, the
   pair is marked unavailable. The same request then continues on the
   on-device path, with no second `beginGeneration`.
6. **Save.** When the stream ends, the reply's `searchSources` gets the
   activity's sources if there are any. This happens even if the stream
   failed after some text arrived. History, the footer and F11 then work
   as for on-device search.

**When provider search is used (`NativeWebSearch.decide`):** all of these
must hold.

- The provider supports it: `CloudProviderID.supportsNativeWebSearch` is
  true for `.openAI`, `.anthropic`, `.chatGPT` and `.claudeCode`, and false
  for `.gemini`. Each provider turns on in the branch in the checkpoint that
  builds it, after its live check. CP6's quality gate decides which stay on
  when the branch merges.
- This provider and model aren't marked unavailable.
- F29's `SearchRouting` picks the web route for the typed question, not
  places or weather.
- The request carries no source material: no attached selection
  (`requestSource.contexts`) and no proposed revision (`requestSource.draft`).

Screen turns never reach `submitCloud`. They go through `submitScreen`,
which F30 leaves alone.

**Interface changes:**

- **`ChatRequest`** gains `var webSearch: CloudWebSearch? = nil`. When
  it's `nil`, there's no search.

  ```swift
  struct CloudWebSearch: Sendable, Equatable {
    /// F29's blocked sites, most recently blocked first.
    var blockedDomains: [String] = []
  }
  ```

- **`CloudProviderError`** gains `webSearchUnavailable(CloudProviderID)`.
  Every client throws it, including `CodexSubscriptionClient` and
  `ClaudeCodeSubscriptionClient`, so the view model checks one error. Its
  message, "Web search isn't available for this model.", appears only in
  logs and tests, because the request falls back.
- **`CloudProviderID`** gains `nativeWebSearchProviders`, the set of
  providers turned on, and `supportsNativeWebSearch`, which reads it.
  `LocalChatViewModel` takes the set as an initializer parameter, so tests
  can pin on-device search.

**New file `Enigma/Cloud/NativeWebSearch.swift`:**

| Member | Job |
| --- | --- |
| `NativeWebSearch.maximumSearches` | 5 |
| `NativeWebSearch.instructions(blockedDomains:namesBlockedDomains:)` | The search instruction (section 3) |
| `NativeWebSearch.decide(...)` | The rules above, as a pure function returning `.native` or `.onDevice` |
| `NativeWebSearch.selectSources(cited:linked:discovered:)` | The sources rule (section 4) |
| `NativeWebSearch.links(in:)` | Markdown links and bare `http`/`https` URLs in an answer, in order |
| `NativeWebSearchAvailability` | A value type: `markUnavailable(_:modelID:)` and `isAvailable(_:modelID:)`. Held by `LocalChatViewModel`, never saved. |
| `NativeWebSearchSources` | One request's bookkeeping, shared by the four clients: whether it searched, the discovered and cited sources, and the answer text. It returns the selection for `.sourcesSelected`. |

**Activity.** No new phases. When the provider starts a search, it emits
`.phase(.searching)`. Results arrive as `.sourcesDiscovered`, which moves
the panel to "Reading sources (n)…". Tokens move it to "Generating
response…", as today. Before `.completed`, the provider emits
`.sourcesSelected` with the chosen sources. If the model didn't search, it
emits nothing.

### 2. Providers

#### OpenAI (API key): `OpenAIResponsesClient`

**The request** with `webSearch` set adds these fields to the body
`makeRequest` builds today:

| Field | Value |
| --- | --- |
| `tools` | `[{"type": "web_search"}]`: default context size, no `user_location`, no `filters` |
| `include` | `["web_search_call.action.sources"]` |
| `max_tool_calls` | `NativeWebSearch.maximumSearches` |
| `instructions` | `ChatResponseStyle.instructions`, then the search instruction, including the blocked sites |

`store: false` stays.

**The stream.** Three cases join `handle`:

| Event | Action |
| --- | --- |
| `response.output_item.added`, item `web_search_call` | Emit `.phase(.searching)` |
| `response.output_item.done`, item `web_search_call` | Take `action.sources[].url` as discovered sources. They have no title, so the site name is used. |
| `response.output_item.done`, item `message` | Take each `output_text` annotation of type `url_citation` (url, title) as a cited source |

**Before `.completed`,** on `response.completed`, the client emits
`.sourcesSelected`.

**Inline citations.** OpenAI requires them to be "clearly visible and
clickable". Its answers carry them as Markdown links in the text, at the
annotation ranges, and Enigma's Markdown renderer makes them clickable. CP0
confirms this. If the links aren't in the text, CP2 appends them in order at
the end of the reply, as `[site](url)`.

**Unavailable.** A 400 for a request with `webSearch` set, whose error
`param` starts with `tools` or whose message mentions `web_search`, becomes
`.webSearchUnavailable(.openAI)`. CP0 records the real error bodies and pins
the match.

#### Anthropic (API key): `AnthropicMessagesClient`

**The tool** comes from `AnthropicMessagesClient.webSearchTool(modelID:blockedDomains:)`,
a static function beside `thinking(modelID:)`:

- **From Claude 4.6 on:** models in a reviewed prefix list get
  `web_search_20260318` with `max_uses` 5 and
  `response_inclusion: "excluded"`. The list covers `claude-opus-4-6`, 4-7
  and 4-8, `claude-sonnet-4-6`, `claude-opus-5`, `claude-sonnet-5`,
  `claude-fable-5` and `claude-haiku-5-5`, and CP0 confirms it. Prefixes
  cover their point releases (`claude-opus-5` covers `claude-opus-5-5`).
- **Older models** get `web_search_20250305` with `max_uses` 5.
- **`blocked_domains`** is the blocked sites, cut to the API's limit, which
  CP0 finds. It's left out when the list is empty: `allowed_domains` and
  `blocked_domains` can't both be sent.

The search instruction is added to `system`.

**The stream** (`content_block_*` events):

| Event | Action |
| --- | --- |
| `content_block_start`, block `server_tool_use` named `web_search` | Emit `.phase(.searching)` |
| `content_block_start`, block `web_search_tool_result` whose `content` is a list | Its `web_search_result` entries (url, title) are discovered sources |
| `content_block_start`, block `web_search_tool_result` whose `content` is an object | A search error such as `too_many_requests` or `max_uses_exceeded`. Logged by code; the model answers with what it has. |
| `content_block_delta`, delta `citations_delta` with a `web_search_result_location` citation | Its url and title are a cited source |
| `message_delta` with `stop_reason: "pause_turn"` | Continue (below) |
| `message_stop` on the final message | Emit `.sourcesSelected`, then `.completed` |

**Continuing a paused turn.** The API can pause a long search turn. To
continue, the paused assistant message goes back unchanged in a new
request.

- **The accumulator.** A new `AnthropicTurnAccumulator`, in
  `Enigma/Cloud/AnthropicTurnAccumulator.swift`, rebuilds every content
  block from the stream:
  - each `content_block_start` block, kept as JSON, including server-tool
    and code-execution blocks it doesn't otherwise understand;
  - then the `text_delta`, `citations_delta`, `input_json_delta`,
    `thinking_delta` and `signature_delta` deltas.
- **The continuation.** The client sends the same body with the rebuilt
  assistant message added, and keeps streaming into the same reply.
- **The limit.** At most 3 continuations. After that, the reply ends with
  the text so far, as `.completed`.

**Unavailable.** A 400 `invalid_request_error` for a request with
`webSearch` set, whose message mentions web search, becomes
`.webSearchUnavailable(.anthropic)`. That covers an organization that
turned search off ("web search is not enabled") and models without search.
CP0 records the bodies.

**Output budget.** `max_tokens` is `prepared.budget.outputTokens`, 4,096
for reviewed Anthropic models. CP0 measures whether search blocks count
against it. If they do, search requests add a fixed margin, set in CP3 from
the measurement.

#### ChatGPT (Codex): `CodexSubscriptionClient` and `CodexAppServer`

**The setting.** The app server keeps starting with `-c web_search="disabled"`
(`CodexAppServer.arguments`), so every thread is search-free unless it asks.
A search thread asks through `thread/start`'s `config` object, which accepts
any keys:

```text
config: { "web_search": "live" }
```

This goes in `CodexSubscriptionClient.threadParameters(model:webSearch:searchMode:)`,
which also swaps in the search `developerInstructions` (section 3).

**If the thread setting doesn't override the launch setting** (CP0 question
1), CP4 uses the first option that works:

1. Drop `web_search="disabled"` from the launch arguments, and send
   `web_search` on every thread: `"disabled"` or `"live"`.
2. Run a second app server, launched with `web_search="live"`, for search
   threads only.

**Policy.** A workspace can limit search modes (`allowedWebSearchModes` in
the config requirements). If `live` isn't allowed, `cached` is used when it
is. If neither is allowed, the client throws
`.webSearchUnavailable(.chatGPT)` before starting the turn.

**The turn.** It stays as it is: read-only sandbox, approvals `never`, no
environments. Web search is a tool OpenAI runs, so it needs no local network
access.

**Events** (checked against the pinned 0.164.0 schema on 2026-10-27):

| Notification | Action |
| --- | --- |
| `item/started` with an item of type `webSearch` | Emit `.phase(.searching)` |
| `item/completed`, `webSearch`, action `openPage` with a `url` | A discovered source |
| `item/completed`, `webSearch`, with `results` | Opaque JSON. Each object with a string `url`, and a `title` if present, is a discovered source. |

**Sources.** Codex reports no citations, so the cited sources are the links
in the final answer (`NativeWebSearch.links(in:)`).

**Unavailable.** A JSON-RPC error from `thread/start` when `config` sets
`web_search`, or a turn that fails before any text with an error about web
search. CP0 records both.

#### Claude Code: `ClaudeCodeSubscriptionClient`

**Checked on 2026-10-27,** with Claude Code 2.1.311 on a subscription login:

- `-p --tools WebSearch --allowedTools WebSearch` searches without a
  permission prompt;
- `init` reports `apiKeySource: "none"`;
- each search arrives as an `assistant` message with a `tool_use` block
  named `WebSearch`, followed by a `user` message whose
  `tool_use_result.results[].content[]` holds `{title, url}`.

**Arguments.**
`ClaudeCodeRuntime.chatArguments(model:effort:streamsInput:webSearch:)`
replaces `--tools ""` with `--tools WebSearch --allowedTools WebSearch`, and
uses the search system prompt (section 3). These stay unchanged:

- `--safe-mode` and `--strict-mcp-config`;
- the empty workspace and the stripped environment.

**Parser.** `ClaudeCodeStreamParser.Event` gains:

| Event | From | Action |
| --- | --- | --- |
| `.toolsListed([String])` | The `system` `init` message | If `WebSearch` is missing, because a policy withheld it, the client stops the process and throws `.webSearchUnavailable(.claudeCode)` |
| `.searchStarted` | A `tool_use` block named `WebSearch`, from the partial-message `content_block_start` or the `assistant` message | Emit `.phase(.searching)` |
| `.searchResults([WebSearchSource])` | `tool_use_result.results` | Discovered sources. Entries that aren't objects with a `content` list are skipped. |

**Sources.** The cited sources are the links in the final answer.

### 3. The search instruction

`NativeWebSearch.instructions` returns this text, which CP0 may tune:

> Web search is on for this message because the user asked for current
> information. Search the web before you answer, at most 5 times, and only
> for what this message needs. Never put personal details, credentials,
> file contents, or text from attachments, screenshots or selections into a
> search query. Base your answer on what you find, and link the pages you
> rely on.

**Blocked sites.** For OpenAI, Codex and Claude Code, a final sentence names
up to 20 of them, most recent first: "Don't use results from these sites:
a.com, b.com." Anthropic gets them as `blocked_domains` instead.

**Where it goes:**

| Provider | Field | Change |
| --- | --- | --- |
| OpenAI | `instructions` | Appended after `ChatResponseStyle.instructions` |
| Anthropic | `system` | Appended after `ChatResponseStyle.instructions` |
| Codex | `developerInstructions` | "Do not use tools, read local files, browse, or take external actions." becomes "Do not read local files or take external actions. Your only tool is web search.", followed by the instruction |
| Claude Code | `--system-prompt` | "You have no tools and cannot read local files, browse, or take external actions." becomes "Your only tool is WebSearch. You cannot read local files, fetch pages, or take other external actions.", followed by the instruction |

**No forced search.** Forced tool choice returns a 400 on current Claude
models, so no provider forces the search; all four rely on the instruction.
CP0 measures how often models comply, and the quality check in CP6 gates
it.

### 4. Sources and citations

`NativeWebSearch.selectSources(cited:linked:discovered:)`:

1. Start with the cited sources, in the order first cited.
2. Add the answer's links:
   - for Codex and Claude Code, these are their citations;
   - for OpenAI and Anthropic, links not already cited.
3. If steps 1 and 2 found nothing, use the discovered sources instead, in
   the order they arrived.
4. Then tidy the list:
   - keep only `isSafeWebLink` URLs;
   - drop duplicates, comparing URLs without their fragment;
   - when a title is missing, use the site name;
   - cap the list at 8.

**Display.** The sources list shows every selected source with its title
and a link. That meets Anthropic's rule that "citations must be included to
the original source". OpenAI's inline links stay in the text (section 2).
Inline citation markers for Anthropic replies are F11's job.

**Saving.** Sources are saved as `WebSearchSource` (title and URL) in
`searchSources`. That format doesn't change, so older chats load as before.

### 5. Privacy

**What changes compared with on-device search (F29):**

| | On-device search (F29) | Provider search (F30) |
| --- | --- | --- |
| Who runs the searches | Enigma, from the Mac | The provider, from its servers |
| Who writes the queries | The typed question, or B11's query prompt | The provider's model, which already receives the conversation |
| Who sees the queries | DuckDuckGo, Mojeek, Wikipedia, and sometimes Startpage | The provider and its search backend |
| Who sees the IP address | The search sites and the result sites Enigma reads | Only the provider, as for any cloud request |
| Location | The city, for nearby questions | Never. Those questions stay on the Mac's search. |

**The new exposure:** queries can draw on earlier turns of the
conversation, which the provider already has. Three things keep it small:

- the search instruction forbids personal details, credentials and attached
  material in queries;
- screen and selection turns stay on on-device search;
- search runs only when Enigma would search anyway.

**Unchanged:**

- **Nothing new is stored.** The availability marks live in memory only.
- **Logs.** Console entries name the provider and the event, never a query
  or a URL, as with F29.
- **OpenAI** keeps `store: false`. Other providers keep their own retention,
  which Enigma doesn't change.
- **Claude Code** fetches nothing from the Mac's network, because `WebFetch`
  stays off.
- **Codex** keeps its read-only sandbox, with no local network access.

### 6. What users see

- **Nothing to set up.** The search chip and `/search` work as with F29.
- **Activity:** "Searching…", then "Reading sources (n)…", then "Generating
  response…". Provider search can take longer than on-device search, because
  the model may search several times. CP0 measures it.
- **Sources** show and save as today. The footer says "web search", F29's
  wording.
- **Settings → Cloud and search → Web search.** F29's note gains a
  sentence: "With OpenAI, Anthropic, ChatGPT and Claude Code, the cloud model
  searches with its provider's own search; questions about places, weather,
  your screen or a selection still search on this Mac. API-key providers
  charge per search." F29's blocked-sites list adds: "Cloud models that use
  their provider's search are asked to avoid these sites, but only Anthropic
  enforces it."
- **No new controls.**

## Failure handling

| Situation | Behavior |
| --- | --- |
| Provider search unavailable before the first event (model, organization policy, plan, tool withheld) | This request continues with on-device search. The pair is marked unavailable until the app quits. |
| A search fails inside the turn (rate limit, `max_uses_exceeded`) | The model answers with what it has. No fallback. |
| The model doesn't search | The reply stands, with no sources. CP6 measures how often. |
| Anthropic `pause_turn` | Up to 3 silent continuations |
| Offline, signed out, or missing key | The same errors as today. No fallback, because the cloud request can't run either. |
| An error after the first event | As today: partial text kept, the error shown, and sources found so far saved |
| Stop | As today: the request is cancelled, Codex interrupts the turn, and the Claude Code process ends |

## Testing

**Offline tests,** deterministic and run in CI:

- **Fixtures** are recorded in CP0 and live in
  `EnigmaTests/Fixtures/CloudSearch/`. They're read through `#filePath`,
  because the test target has no resources phase.
- **Scrubbing.** Account, organization, thread and request IDs are replaced
  with placeholders, and nothing personal is in the questions.

| Test class | Covers |
| --- | --- |
| `NativeWebSearchTests` (new) | **Routing:** `decide` for each provider, route (web, places, weather), source material and availability state; Gemini never native. **Sources:** `selectSources` order, deduplication, the cap of 8, unsafe links dropped, site-name titles. `links(in:)`. **Instruction:** the text, and the blocked-sites sentence. |
| `CloudModeTests` | **OpenAI:** the request with and without search; the stream fixtures produce the expected activity and selected sources; the 400 mapping. **Anthropic:** the tool version by model; `blocked_domains`; result lists and error objects; `citations_delta`; the `pause_turn` continuation body equals the rebuilt message; the 3-continuation cap; the 400 mapping. |
| `CodexSubscriptionTests` | `threadParameters` with search; `webSearch` items; links from the answer; the policy check; the unavailable mapping |
| `ClaudeCodeSubscriptionTests` | `chatArguments` with search; parser events from the recorded fixture; `init` without `WebSearch` |
| `WebSearchTests` | **Provider search:** the on-device provider isn't called; sources are saved from provider events. **Fallback:** on-device search runs once, and the pair is remembered. **On-device paths:** places, weather, selection and Gemini requests. |
| `RequestLifecycleTests` | Stop during a provider search; acceptance at the first event; a failure before acceptance keeps the draft; a failure after it keeps text and sources |

**Live checks,** on the owner's Mac and not in CI. `NativeWebSearchLiveTests`
skip unless `ENIGMA_NATIVE_SEARCH_LIVE` is set. Each runs one question per
route:

- the API keys come from `TEST_RUNNER_ENIGMA_OPENAI_KEY` and
  `TEST_RUNNER_ENIGMA_ANTHROPIC_KEY`, never written or logged;
- ChatGPT and Claude Code use the Mac's sign-ins.

**Quality check (CP6).** For each provider route:

- **The questions:** 20 web questions from F29's
  `scripts/web-search-queries.json` (the news, facts, docs, health-finance,
  reviews and encyclopedic categories).
- **The runs:** each question runs twice on the same model, once with
  provider search and once with on-device search.
- **The judge:** F29's `scripts/evaluate-web-search.py` compares the two,
  through a new `--compare native,onDevice` mode.
- **The cost:** 20 to 100 paid searches per API route (at most about $1,
  plus tokens), and plan usage on the subscriptions. The owner approves the
  runs first.

**The gate, per route.** Provider search stays on for a route when the
branch merges only if:

- it searched on 18 or more of the 20 questions;
- at least 2 sources were shown on 18 or more;
- no source fails `isSafeWebLink` or matches F29's unsafe or spam lists;
- the judge prefers provider search, or calls a tie, on 80% or more of the
  questions.

A route that fails is turned off again, by removing it from
`nativeWebSearchProviders`, and keeps on-device search. The owner decides what's next.

## Docs

- **`docs/Web-Search.md`** gains a section, "Cloud models' own search":
  - which routes use it, and when;
  - sources and fallback;
  - the privacy table from section 5;
  - costs: about $10 per 1,000 searches on OpenAI and Anthropic API keys,
    plus tokens, checked on the pricing pages during CP6; nothing extra on
    the subscriptions;
  - limitations: blocked sites, and screen and selection turns.

  Its "How it works" and "Tests" sections are updated.
- **Updated:**
  - `docs/ChatGPT-Setup.md`: web search is on for search requests only, in
    `live` mode;
  - `docs/Claude-Code-Setup.md`: `WebSearch` for search requests only;
  - `docs/Cloud-Model-Selection.md`: which providers search natively, and
    Gemini's on-device search;
  - `docs/Chat.md`: the provider-search branch of "Request lifecycle";
  - `docs/Testing.md`: the live checks and the quality check.
- **Release notes** say cloud models now use their provider's search.
- **`to-do.md`:** F30 points here and to the plan.
- **The report.** CP6 adds `docs/history/<date>-native-search-evaluation.md`,
  with metrics and judge results only: no answers or page text.

## Delivery

**Branch and order.** The work runs in checkpoints on
`feat/f30-native-cloud-search`, in a worktree outside `~/Documents`. It
starts from `main` once F29 is merged.

**Each checkpoint** follows F29's loop:

1. A fresh worker agent builds it from its brief.
2. A fresh reviewer agent audits it, following `docs/reviewer.md` and the
   checkpoint's checklist.
3. The worker fixes the findings.
4. The coordinator verifies and commits, and records the hand-off.

The implementation plan, written after this spec is approved, holds each
brief.

| Checkpoint | Goal | Exit criteria |
| --- | --- | --- |
| CP0 Spike | Answer the open questions below with throwaway probes on the owner's accounts, and record fixtures | A written answer per question; fixtures scrubbed and saved |
| CP1 Shared plumbing | `CloudWebSearch`, the new error, `NativeWebSearch`, availability, the view model's provider-search path with acceptance, fallback and saving. `nativeWebSearchProviders` stays empty, so behavior doesn't change yet. | Tests pass; no visible change |
| CP2 OpenAI | Request, stream, inline-citation check and error mapping; turn on `.openAI` | Tests pass; the live check passes |
| CP3 Anthropic | Tool by model, blocked domains, stream, citations, the accumulator and continuation, error mapping, output budget; turn on `.anthropic` | Tests pass; the live check passes |
| CP4 ChatGPT (Codex) | The thread setting (as CP0 chose), instructions, events, links, policy check, error mapping; turn on `.chatGPT` | Tests pass; the live check passes |
| CP5 Claude Code | Arguments, system prompt, parser, `init` check; turn on `.claudeCode` | Tests pass; the live check passes |
| CP6 Quality check, docs and audit | The comparison per route, the report, the docs, release notes, `to-do.md`, and a final check in the running app | The gate passes on each route that ships; docs match behavior |

**Accounts.** CP0 and the live checks need the owner's OpenAI and Anthropic
API keys, passed as environment variables, plus the ChatGPT and Claude Code
sign-ins on the owner's Mac. Without a key for a provider, its checkpoint is
built from the documented shapes, and its live check and turn-on wait.

**Open questions for CP0:**

1. **Codex thread setting.** Does `thread/start`'s `config.web_search`
   override the launch argument `-c web_search="disabled"` in 0.164.0? What
   are the requirements method and the shape of `allowedWebSearchModes`?
2. **Codex events.** With `live` on a ChatGPT login:
   - the order of `item/started` and `item/completed` for `webSearch`;
   - what `results` holds;
   - whether answers contain Markdown links;
   - what a disallowed mode returns.
3. **OpenAI stream.** The event order with `web_search` on the default
   model, `gpt-5.6-luna`:
   - the item shapes, and `action.sources`;
   - whether `output_text` carries the links at the annotation ranges;
   - whether `max_tool_calls` is accepted;
   - the error body for a model without search.
4. **Anthropic stream.** On the default Anthropic model:
   - the event order with `web_search_20260318`, including code-execution
     blocks, and what `response_inclusion: "excluded"` leaves out;
   - whether search blocks count against `max_tokens`;
   - the error bodies when search is off or unsupported;
   - the `blocked_domains` size limit;
   - which listed model prefixes accept the new tool.
5. **Claude Code fixture.** Record a multi-search question:
   - Do answers end with a "Sources:" list of their own? If so, should the
     instruction ask them not to?
   - Does `tool_use_result.results` ever hold plain strings?
6. **Compliance.** On 10 web questions per route, how often does the model
   search with only the instruction?
7. **Latency.** Time to first token and total, with provider search and with
   on-device search, for 5 questions per route.

## Out of scope

- **Gemini grounding with Google Search,** decided against. It could return
  with a renderer for Google's search suggestions.
- **Sending a location** to provider search.
- **Provider search on screen and selection turns.**
- **Page-fetching tools:** Claude Code `WebFetch` and Anthropic `web_fetch`.
- **A setting to prefer on-device search** on cloud routes.
- **Inline citation markers** for Anthropic replies (F11).
- **Search in other modes:** File Mode, `/messages`, and tool modes
  (`CloudToolLoop`, and the Codex and Claude Code tool modes).
- **Letting the model decide when to search** on other turns (F26).
- **Showing the provider's queries** in the activity panel.
- **Reusing earlier search results** in later turns. Enigma sends history as
  text, as today.
