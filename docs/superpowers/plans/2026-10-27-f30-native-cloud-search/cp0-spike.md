# CP0: Spike — answer the open questions

Read [agent-workflow.md](agent-workflow.md) and the spec in full. The spec's
"Open questions for CP0" list is this checkpoint's scope.

## Goal

Answer the spec's six open questions with throwaway probes, and check F32's
names, so later checkpoints build on facts. **No product code comes out of
this checkpoint.**

- Create the worktree first: branch `feat/f30-native-cloud-search` from
  `main`, in a folder outside `~/Documents`, beside F29's worktree.
- Probes live in a scratch folder outside the repository. Python 3
  (standard library) or `curl` suits the HTTP probes, and Python's
  `subprocess` suits the Codex app server and Claude Code.
- Only two things are committed: this brief's Hand-off with the findings,
  and the scrubbed fixtures with their README.

## Starting point

- **F32 is on `main`.** Every cloud catalogue model is flagged
  (`CloudModelCapabilities.supportsNativeTools`), so every cloud turn
  without files or a screenshot goes through `LocalChatViewModel.submitNative`
  and the provider's streaming tool loop.
- **Where the tool loops are:**
  - `Enigma/Cloud/CloudToolCalling.swift`: `CloudToolLoop`, and the
    `ToolCallingChatProvider` extensions of `OpenAIResponsesClient`,
    `AnthropicMessagesClient`, `GeminiContentClient`,
    `CodexSubscriptionClient` and `ClaudeCodeSubscriptionClient`;
    `CodexToolMode` (dynamic tools in `thread/start`) and
    `ClaudeCodeToolMode` (an SDK MCP server named by `ClaudeCodeToolMode.server`);
  - `Enigma/Cloud/CloudToolStreaming.swift`: the `ToolStreamAssembler`s;
  - F32's fixtures: `EnigmaTests/Fixtures/F32/` (`openai/`, `anthropic/`,
    `gemini/`), several written from the docs rather than recorded.
- **What each route sends today:** OpenAI `tools` of type `function`,
  `parallel_tool_calls: false`, `store: false`, and `tool_choice` for a
  required tool on step 1; Anthropic client tools, `tool_choice` except
  under `/think`; Codex `dynamicTools` with `-c web_search="disabled"` at
  launch; Claude Code `--tools ""`, `--mcp-config` with the SDK server and
  `--allowedTools` of the `mcp__…` names.
- **Facts checked on 2026-10-27** (recheck only what's marked): this
  brief's first version lists them
  (`git show 6f2fec4:docs/superpowers/plans/2026-10-27-f30-native-cloud-search/cp0-spike.md`).
  In short: Codex 0.164.0's `ThreadStartParams.config` accepts any keys and
  `webSearch` items are `{id, query, action?, results?}`; Claude Code
  2.1.311's `--tools WebSearch` searches without a prompt and reports
  `{title, url}` results; Anthropic's and OpenAI's documented shapes. **The
  pinned Codex may have moved** since (F32 and the daily refresh): recheck
  the schema against the installed one.

## Tasks

### Task 0.1: F32 names (Q0)

- [ ] **Check each name** in the plan's Global Constraints "F32 names" list
  against `main`, with `grep -rn`. Also find:
  - where `submitNative` builds the toolbox and where a turn's draft is
    accepted (the point after which an unavailable error can't fall back);
  - how `SavingMessagesGate.didReturnMessageText` is called relative to the
    tool result being returned to the loop (it must be possible to stop
    before delivery);
  - the pinned Codex version and its schema's `ThreadStartParams` and
    `webSearch` item.
- [ ] **Record** each name as found, or its new name, in the findings table.

### Task 0.2: OpenAI (Q1)

**Owner-run.** Write `probe-openai.sh`, which reads `ENIGMA_OPENAI_KEY` from
the environment and writes raw output to a folder outside the repository.
Ask the owner to run it: about 6 requests and up to 15 searches.

- [ ] **The script's requests,** to `/v1/responses` with `"stream": true`
  and `"store": false`, model `gpt-5.6-luna` (or `ENIGMA_OPENAI_MODEL`), and
  F32's body shape:
  1. **Search beside a function tool.** `tools` holds one function (copy
     `propose_edit`'s definition from F32) plus `{"type": "web_search"}`;
     `include: ["web_search_call.action.sources"]`; `max_tool_calls: 5`.
     Question: "What is the latest stable Swift release? Link your source."
  2. **Multi-search:** "Compare the current prices of the cheapest MacBook
     Air and the cheapest MacBook Pro in the US. Link your sources."
  3. **Forced:** request 1 with `tool_choice: {"type": "web_search"}` on a
     question that doesn't need search ("What is 2 + 2?").
  4. **Replay:** a second step whose `input` adds request 1's output items
     (the `web_search_call` and `message`) and a new user line, to see which
     items `store: false` accepts back.
  5. **`max_tool_calls: 1` with a function call needed**, to see whether
     the limit counts function calls.
  6. **An invalid tool,** `{"type": "web_search", "search_context_size": "huge"}`,
     for a 400 that names `tools`; and an older model (`gpt-4o-mini`) with
     the tool, to see whether it searches or rejects it.
- [ ] **Answer Q1** from the recordings: the event order and item shapes;
  whether `action.sources` has titles; whether `output_text` carries the
  links as Markdown at the annotation ranges; `max_tool_calls`; forced
  choice; replay; the error JSON.
- [ ] **Save the fixtures:** `openai-search-and-function.sse` (request 1),
  `openai-multi-search.sse` (request 2), `openai-replay-request.json` (the
  body that worked in request 4, scrubbed), `openai-invalid-tool-error.json`,
  and `openai-model-error.json` if request 6's older model failed.

### Task 0.3: Anthropic (Q2)

**Owner-run.** Write `probe-anthropic.sh`, which reads
`ENIGMA_ANTHROPIC_KEY`. About 14 requests and up to 35 searches.

- [ ] **The script's requests,** to `/v1/messages` with `"stream": true`,
  `anthropic-version: 2023-06-01`, model `claude-sonnet-4-6` (or
  `ENIGMA_ANTHROPIC_MODEL`), `max_tokens` 4096, and F32's client tools:
  1. **The new tool beside a client tool.** `web_search_20260318` with
     `max_uses: 5` and `response_inclusion: "excluded"`, plus F32's
     `propose_edit`, on the multi-search question.
  2. **The same with `max_tokens` 1024,** to see whether search blocks
     count against it.
  3. **A step after a client tool call:** a question that makes the model
     search, then call `propose_edit` (give it a selection to edit with a
     fact to check). Answer the call, and send the next step with every
     block of the assistant message unchanged. Record what the API needs.
  4. **A paused turn:** "Find the current price of each of these 12
     products and list them with sources: …" (12 well-known products). If
     a pause comes, continue with the paused message's blocks, and with all
     blocks so far on a second pause.
  5. **Forced:** `tool_choice: {"type": "tool", "name": "web_search"}` on
     "What is 2 + 2?".
  6. **Blocked domains:** lists of 10, 64, 100 and 500 made-up domains
     (`blocked-0001.example`, …): the largest accepted, and the error above
     it.
  7. **The basic tool** `web_search_20250305` on `claude-haiku-4-5`, and the
     new tool on it, for the error JSON.
  8. **Each candidate prefix,** one request with `max_uses: 1` per model the
     account can call, from `claude-opus-4-6`, `claude-sonnet-4-6`,
     `claude-opus-4-7`, `claude-opus-4-8`, `claude-opus-5`,
     `claude-opus-5-5`, `claude-sonnet-5`, `claude-sonnet-5-5`,
     `claude-fable-5`, `claude-fable-5-1` and `claude-haiku-5-5`.
  9. **Organization off (optional),** if the owner is willing to turn search
     off in the Claude Console for a minute; otherwise use the docs' wording
     and mark it so.
- [ ] **Answer Q2,** including the event order with code-execution blocks
  and what `response_inclusion: "excluded"` leaves out.
- [ ] **Save the fixtures:** `anthropic-search-and-tool.sse` (request 1),
  `anthropic-step-replay-request.json` (request 3's second body, scrubbed),
  `anthropic-pause-turn.sse` and `anthropic-pause-continuation.sse` if a
  pause happened, `anthropic-blocked-domains-error.json`,
  `anthropic-tool-version-error.json`, and
  `anthropic-search-disabled-error.json` if recorded.

### Task 0.4: Codex (Q3)

**Approval needed:** the owner approves about 8 ChatGPT turns.

- [ ] **Write the probe.** It starts the app server the way Enigma does
  (the installed executable, `CodexRuntimeConfiguration.live`'s environment
  and every `-c` override, including `web_search="disabled"`), sends the
  `initialize` handshake, then `thread/start` with F32's
  `CodexToolMode.threadParameters` fields (its `dynamicTools` included) and
  `turn/start`, answers any dynamic tool call with a fixed result, and
  records every notification as JSONL.
- [ ] **Run these:**
  1. **The thread setting:** `config: {"web_search": "live"}` with the
     dynamic tools, on the Swift release question. Did a `webSearch` item
     appear?
  2. **Without `config`:** confirm nothing is searched.
  3. **If run 1 didn't search,** try spec §3's two options and record which
     works.
  4. **`configRequirements/read`:** the response, and
     `allowedWebSearchModes`.
  5. **Multi-search,** recording the `item/started` and `item/completed`
     order, every `action` type, what `results` holds, and whether the
     answer has Markdown links.
  6. **A dynamic tool call in a search thread:** a question that makes the
     model call the dynamic tool; record the order of `webSearch` items and
     the tool call.
- [ ] **Save the fixtures,** with thread and turn IDs set to `thread-one`
  and `turn-one`: `codex-web-search.jsonl` (run 5),
  `codex-search-and-dynamic-tool.jsonl` (run 6), and
  `codex-thread-start-error.json` if any run gave a JSON-RPC error.

### Task 0.5: Claude Code (Q4)

**Approval needed:** about 4 Claude Code runs.

- [ ] **Run the multi-search question** with F32's tool-mode arguments,
  `--tools WebSearch` in place of `--tools ""`, and `WebSearch` added to
  `--allowedTools`, answering the SDK MCP server's `tools/list` and any
  `tools/call` as F32's `ClaudeCodeToolMode.respond` does, with a fixed
  result. Use F32's environment and an empty working folder.
- [ ] **Answer Q4:** the `init` tools list (does it show `WebSearch` and the
  MCP tools?); which events mark a `WebSearch` call; does the answer end
  with its own "Sources:" list; does `tool_use_result.results` ever hold
  plain strings.
- [ ] **Save the fixtures:** `claude-code-web-search.jsonl`, scrubbed of
  `session_id`, `uuid` and the account fields in `init`; and
  `claude-code-init-without-websearch.jsonl`, its `init` line without
  `WebSearch`, marked **derived** in the README.

### Task 0.6: The restart (Q5)

Use the probes above; no extra searches.

- [ ] **For each route,** show that Enigma can stop a request between a
  tool call and its result, with nothing delivered:
  - OpenAI and Anthropic: cancel the stream after the function call
    arrives, and send nothing more;
  - Codex: answer nothing to the dynamic tool call, send `turn/interrupt`,
    and record the notifications that follow;
  - Claude Code: answer nothing to the MCP `tools/call`, end the process as
    F32's Stop does, and record what it prints.
- [ ] **Record** in each case whether the provider could have received the
  result (it must not), and how long the stop took.

### Task 0.7: Latency (Q6)

**Owner-run and approved runs:** 5 questions per route.

- [ ] **Choose 5 web questions** (news, changing facts, docs, reviews) and
  list them in the Hand-off. CP6 will put them in
  `scripts/web-search-queries.json`.
- [ ] **For each route,** record per question: whether it searched, time to
  first text, total time, and the number of sources; with provider search,
  and with Enigma's `web_search` on Brave if the owner runs it with a key
  (otherwise mark it not measured).

## Exit criteria

- All seven rows of the findings table below are filled in, and every
  "owner decision needed" is marked.
- The fixtures and `EnigmaTests/Fixtures/CloudSearch/README.md` are saved,
  scrubbed per the workflow.
- No probe code or raw recording is left in the worktree.
- `git status` shows only this brief and the fixtures.

## Reviewer checklist

- **Check the fixtures** for anything the workflow says to scrub: IDs,
  emails, encrypted fields, keys, locations. Check each README line matches
  its file.
- **Check each decision** follows from the recorded evidence. Q3's thread
  setting, Q2's replay and prefix list, and Q5's restart matter most.
- **Never rerun a live probe.** Reason from the recordings.

## Hand-off

*Filled in by the CP0 worker.*

| # | Question | Answer | Evidence | Decision for later checkpoints |
| --- | --- | --- | --- | --- |
| Q0 | F32 names on `main` | All found, same names. Acceptance on cloud routes comes before the stream starts; the Messages gate can't throw yet | Code on `main` (8db6352); Codex 0.164.0 schema | See [Q0](#q0-f32-names) |
| Q1 | OpenAI: events beside functions, links, `max_tool_calls`, forced choice, replay, errors | **Unrecorded: no API key.** From the docs: items and citations as the spec says; `max_tool_calls` counts built-in calls; forcing is documented (form to confirm); replay and error bodies aren't documented. **Owner decided:** no `user_location` (US default accepted) | Docs (2026-10-29); synthetic `openai-*` fixtures | See [Q1](#q1-openai) |
| Q2 | Anthropic: events, step replay, budget, `pause_turn`, forced choice, blocked-domains limit, prefixes, errors | **Unrecorded: no API key.** From the docs: events, replay rule and `pause_turn` as the spec says; the prefix list is confirmed. **Owner decided:** `response_inclusion: "full"`. Forcing a tool 400s on Opus 5.5, Sonnet 5.5, Fable 5.1 and Mythos 5.1. Budget, blocked-domains limit and error text aren't documented | Docs (2026-10-29); synthetic `anthropic-*` fixtures | See [Q2](#q2-anthropic) |
| Q3 | Codex: thread setting with dynamic tools, `allowedWebSearchModes`, events, links | The thread's `config.web_search: "live"` overrides the launch setting with dynamic tools present. `allowedWebSearchModes` is `null` here. Answers carry Markdown links | `codex-web-search.jsonl`, `codex-search-and-dynamic-tool.jsonl` | See [Q3](#q3-codex) |
| Q4 | Claude Code: `init` list, events, "Sources:" list, plain-string results | `init` lists `WebSearch` and the MCP tools. Plain-string results come on every search. 5 of 6 answers end with "Sources:" | `claude-code-web-search.jsonl` | See [Q4](#q4-claude-code) |
| Q5 | The restart on each route | Codex and Claude Code: yes, nothing delivered. OpenAI and Anthropic: unmeasured, but nothing is sent until Enigma sends the next step | Probe recordings (not committed) | See [Q5](#q5-the-restart) |
| Q6 | Latency per route | Codex and Claude Code measured; OpenAI and Anthropic not measured (no key); Brave not measured (owner) | Probe recordings (not committed) | See [Q6](#q6-latency) |

### Q0: F32 names

- **Names.** Every name in the plan's "F32 names" list exists on `main`
  (8db6352) under the same name, in the files the plan gives.
- **The toolbox.** `submitNative` builds it in `nativeToolbox(plan:destination:sessionID:responseID:requestID:evidenceTokens:)`:
  the search part is `WebSearchTool`, and the Messages part is wrapped in
  `SavingMessagesGate`.
- **Acceptance isn't the reply starting.** On cloud routes `acceptNative`
  runs right after `CloudContext.prepare`, *before* `provider.stream`
  starts. On local routes it runs at the first text or tool call.
- **The gate.** `MessagesTools` awaits `gate?.didReturnMessageText()` inside
  `listConversations`, `getMessages` and `searchMessages`, after reading and
  before returning the result, so a result can be held back there. But
  `MessagesAccessGate.didReturnMessageText()` is `async`, not `throws`.
- **How F32 withholds a result.** `MessagesTools.execute` turns every error
  into an ordinary failed result (`success: false`), which *is* delivered to
  the model, a declined card included (`declinedResult`). Two exceptions are
  terminal: a `CancellationError` becomes `.cancelled`, which `submitNative`
  treats as Stop, and a `MessagesError` with a `privacyPane` becomes
  `.messages(error)`. Only a terminal result with an `AgentToolStop` is
  withheld:
  `CloudToolLoop.run` throws its `stopError` before delivering, and
  `ClaudeCodeToolMode.respond` throws it instead of answering.
  `AgentToolStop` has only `.cancelled` and `.messages(_)` today. On Codex,
  `CodexToolMode.handle` answers every call, terminal results included (it
  records only `.messages` stops), and `CodexAppServer.receiveServerRequest`
  writes that answer even after Stop clears the handler.
- **Codex 0.164.0** is still pinned (`CodexRuntime.version`), and its
  generated schema matches the 2026-10-27 facts, with two refinements:
  `webSearch.results` is typed `array | null` (entries opaque), and the
  `search` action has `queries: [String]?` beside `query`.
- **Decisions:**
  - CP1: "before the reply starts" is tracked in `submitNative` as no
    `.token` and no tool call yet, not by acceptance.
  - CP1: the restart must use the terminal path, not a thrown error. Add a
    restart case to `AgentToolStop` (its `error` being
    `ProviderSearchRestart`), and have `MessagesTools` return a terminal
    result with it when the gate says the result must be held back (for
    example `didReturnMessageText()` returning whether delivery may go on).
    A plain throw from the gate would be delivered as a failed result, and a
    `CancellationError` would look like Stop. Both are changes to F32's
    `AgentToolStop` and `MessagesAccessGate`. The restart's terminal
    result `text` must never contain the read output: Codex's `handle`
    sends `result.codex` back to the model.
  - CP4: `CodexToolMode.handle` and its `Stop` must record the restart stop
    and answer the call with stop text only (or not at all), then interrupt
    the turn. Today's Codex path would answer the call with its result.
  - CP4: read `action.queries` as well as `action.query`.

### Q1: OpenAI

**Unrecorded.** The owner has no OpenAI API key (2026-10-29), so the probe
(`probe-openai.sh`, kept in the scratch folder) never ran. These answers come
from OpenAI's docs, fetched 2026-10-29: the web search guide
(developers.openai.com/api/docs/guides/tools-web-search), the Responses
reference and streaming events, the conversation-state and reasoning guides,
and the pricing page.

- **The tool.** `{"type": "web_search"}`; `web_search_preview` is legacy.
  Optional `search_context_size` (`low`, `medium` default, `high`) and
  `filters` (`allowed_domains`, `blocked_domains`, up to 100 each).
- **Location.** If `user_location` is omitted, it "defaults to the United
  States". Sending `{"type": "approximate"}` with no other fields avoids that,
  and carries no location. **Owner decision needed:** the spec says no
  `user_location`, which means US-biased results; the alternative is the
  empty `{"type": "approximate"}`, which sends nothing about the user but is
  a location field.
- **Items.** `web_search_call` is `{id, type, status, action}`; `action` is
  `search` (`query`, `queries`, and `sources: [{type: "url", url}]` with the
  `include`), `open_page` (`url`) or `find_in_page` (`url`, `pattern`).
  Sources have **no title**. The answer's `output_text` has `annotations` of
  type `url_citation` with `url`, `title`, `start_index`, `end_index`.
- **Events.** `response.output_item.added` and `.done` are documented; the
  `response.web_search_call.*` event names and payloads are not. CP2 should
  key off the item in `output_item.added`/`.done`, as the spec's table does.
- **Links in the text: not documented** (the docs' example text is
  truncated). The spec's fallback stands: if the cited links aren't in the
  text, CP2 appends them.
- **`max_tool_calls`:** "the maximum number of total calls to built-in tools
  that can be processed in a response." Function calls aren't built-in tools,
  so CP2 sends `max_tool_calls: 5`. Unverified.
- **Forced choice: documented, form unconfirmed.** The web search guide
  says: "Use `tool_choice: "required"` or a specific web search tool choice
  when search must run." The hosted-tool `tool_choice` types list
  `web_search_preview` but not `web_search`, and plain `required` could
  force `propose_edit` or a Messages tool instead. The Responses reference
  also has `{"type": "allowed_tools", "mode": "required", "tools": [...]}`.
  CP2's candidate for a typed `/search` is that form with
  `[{"type": "web_search"}]` on step 1, verified in its live check, with
  F32's instruction as the fallback.
- **Replay with `store: false`: unverified.** The docs say to keep every
  output item for manual history. The Responses input schema marks `id` and
  `status` **required** on a `web_search_call` input item, but it also
  requires them on output `message` items, which F32's `replayable` already
  strips on every step that wrote text before a call. So the schema doesn't
  settle what the API enforces. The reasoning guide also says reasoning
  items carry `encrypted_content` under `store: false` and recommends
  passing them back; F32 drops them, which could matter for a kept `ws_` ID.
  CP2's live check tries, in order: (1) strip `id`/`status` as F32 does;
  (2) keep `id`/`status` on `web_search_call` items; (3) drop the item.
  `openai-replay-request.json` models candidate 2.
- **Errors: not documented.** No error body for an unsupported tool or
  model. CP2 maps the spec's rule (400 whose `param` starts with `tools`, or
  whose message mentions `web_search`) without a recorded body.
- **Models.** The guide recommends gpt-5.5 and lists gpt-4.1 and
  gpt-4.1-mini; `gpt-5` with minimal reasoning can't search; gpt-4o-mini
  isn't listed. gpt-5.6-luna isn't named either.
- **Cost.** $10 per 1,000 calls plus search content tokens at the model's
  rates (gpt-4o-mini and gpt-4.1-mini bill a fixed 8,000 input tokens per
  call).

### Q2: Anthropic

**Unrecorded,** for the same reason. From Anthropic's docs, fetched
2026-10-29: the web search tool, server tools, streaming, define-tools,
code execution and citations pages.

- **Versions.** `web_search_20250305` (basic), `web_search_20260209`
  (dynamic filtering through code execution) and `web_search_20260318`
  (adds `response_inclusion`: `full`, the default, or `excluded`). Dynamic
  filtering needs Claude 4.6 or later. Its default `allowed_callers` is
  `["code_execution_20260120"]`; models without programmatic tool calling
  need `allowed_callers: ["direct"]` or the request fails with a 400.
- **Models.** The web search page lists Fable 5.1, Mythos 5.1, Fable 5,
  Mythos 5, Mythos Preview, Opus 5.5, Opus 5, Sonnet 5.5, Sonnet 5,
  Haiku 5.5, Haiku 4.5, Opus 4.8, 4.7, 4.6, Sonnet 4.6, Opus 4.5 and
  Sonnet 4.5. The spec's prefixes (`claude-opus-5`, `claude-sonnet-5`,
  `claude-fable-5`, …) cover the 5.5 and 5.1 releases; `claude-mythos-*`
  isn't in the spec's list. The programmatic tool calling page lists every
  model in the spec's prefix list as supported (Opus 4.6, 4.7, 4.8, Sonnet
  4.6, Opus 5 and 5.5, Sonnet 5 and 5.5, Fable 5 and 5.1, Haiku 5.5), and
  Haiku 4.5 as not supported. So the spec's list is confirmed, and none of
  those models needs `allowed_callers: ["direct"]`, which would switch off
  the dynamic filtering the spec chose this tool for.
- **Events.** As the spec's table: `server_tool_use` (`srvtoolu_…`, input
  through `input_json_delta`), then `web_search_tool_result` arriving whole in
  `content_block_start` with `web_search_result` entries `{url, title,
  encrypted_content, page_age}`. A search error is an object,
  `{type: "web_search_tool_result_error", error_code}`, with codes
  `too_many_requests`, `invalid_tool_input`, `max_uses_exceeded`,
  `query_too_long`, `request_too_large` and `unavailable`. Text citations are
  `web_search_result_location {url, title, encrypted_index, cited_text}`;
  the docs show `citations_delta` only for documents, so its web-search form
  is inferred. `usage.server_tool_use.web_search_requests` counts searches.
- **`response_inclusion: "excluded"`** drops the nested `server_tool_use` and
  `web_search_tool_result` pairs that a finished code execution consumed. So
  with the spec's tool, the discovered results may never reach Enigma, only
  the citations. The order and shape of the code-execution blocks
  (`bash_code_execution_tool_result`, a `caller` field) aren't documented
  well enough to write a fixture. The synthetic Anthropic fixtures model
  direct calls only (`allowed_callers: ["direct"]`); the spec's own
  configuration is unfixtured and must be recorded in CP3's live check.
- **`excluded` also hides the searching signal.** Searches come back in full
  only when called directly or when the code execution paused. With the
  spec's configuration, the spec §3 trigger (a `server_tool_use` named
  `web_search`) may never arrive, so Anthropic replies may show no
  "Searching…" or "Reading sources (n)…", and replies that cite nothing
  would have no sources. Whether citations still arrive is unrecorded.
  **Owner decision (2026-10-29): `"full"`.** It keeps the search blocks and
  the spec's event table; the spec, plan and CP3 brief now say `full`.
- **Step replay.** Send the assistant's blocks back "exactly as you received
  them", `encrypted_content` and `encrypted_index` included; a changed or
  missing one gives a 400. When search and a client tool come in the same
  turn, `stop_reason` is `tool_use` and the `server_tool_use` may have no
  result yet: the API runs it on the next request. The next user message must
  hold only `tool_result` blocks, with the same `tools`.
- **`pause_turn`.** Send the paused response back as it is, with the same
  tools; it can pause again. The docs advise capping continuations but give
  no number, so the spec's 3 stands.
- **Forced choice: no.** A `tool_choice` naming a server tool isn't
  documented. Separately, `tool_choice` `any` or `tool` **returns a 400 on
  Opus 5.5, Sonnet 5.5, Fable 5.1 and Mythos 5.1**, and with manual extended
  thinking. CP3 uses F32's instruction for `/search` on Anthropic, never
  `tool_choice`.
- **Budget: not documented** whether search blocks count against
  `max_tokens`. CP3 can't set the margin from a measurement.
- **Blocked domains:** mutually exclusive with `allowed_domains`; no list
  size limit is documented (a long list can give `request_too_large`).
- **Errors.** An organization with search off gives a 400
  `invalid_request_error` "that says web search is not enabled"; the exact
  text isn't given. No text for an unsupported model or tool version. The
  Models API's `capabilities.server_tools.web_search.supported` says whether
  a model accepts search.
- **Display.** "When displaying API outputs directly to end users,
  citations must be included to the original source." $10 per 1,000
  searches plus tokens; code execution is free with the 20260209+ tools.

### Q3: Codex

Codex 0.164.0 app server, launched as Enigma launches its tool-mode server
(every `-c` override, `web_search="disabled"` included), gpt-5.6-luna,
effort high, F32's thread and turn parameters.

- **The thread setting works.** With `config: {"web_search": "live"}` beside
  `dynamicTools`, run 1 searched once. Without it (run 2) nothing was
  searched, and the model answered from memory. Neither fallback option in
  spec §3 is needed.
- **Policy.** `configRequirements/read` returns `requirements` with
  `allowedWebSearchModes: null`: no limit on this account. A disallowed
  mode couldn't be tried.
- **Events.**
  - `item/started` `webSearch` arrives with `query: ""`, `action: null`,
    `results: null`; `item/completed` has all three.
  - Actions seen: `search` (with `query`, or `query: null` and a `queries`
    list), `other` and `findInPage`. No `openPage` came up.
  - `results` is a list of `{type: "text_result", domain, ref_id, snippet, title, url}`,
    with `thumbnail_url` on `other` items: 1 to 40 or more per search, up to
    110 in one turn.
  - Several searches are sequential started/completed pairs (run 5: 4).
  - With a dynamic tool (run 6): `item/tool/call`, answered, then the
    `webSearch` pair. A dynamic call also shows as a `dynamicToolCall` item.
- **Links.** Every answer had Markdown links (1 to 12), inline and often in a
  closing "Sources:" line.
- **Side note.** Each thread logs a `configWarning` that `tools.view_image`
  is ignored, and a warning about `skip_host_skill_discovery`. Both come
  from F32's existing overrides, not from F30.
- **Decisions for CP4:**
  - Send `config.web_search` on provider-search threads only; keep the
    launch argument.
  - Mode: `null` or absent means any mode, so `live`. A present list
    (including `[]`) is followed: `live` if listed, else `cached` if listed,
    else `.webSearchUnavailable(.chatGPT)`.
  - `.phase(.searching)` on `item/started`. Sources on `item/completed`:
    `results[]` objects with a string `url` (and `title`), plus `action.url`
    on `openPage` and `findInPage`.
  - The disallowed-mode error is unrecorded: map a `thread/start` JSON-RPC
    error that mentions web search to unavailable, as the spec says.

### Q4: Claude Code

Claude Code 2.1.312, model `haiku` (resolves to claude-haiku-5-5, owner's
choice), F32's tool arguments with `--tools WebSearch` and `WebSearch` in
`--allowedTools`, the SDK MCP server answered as `ClaudeCodeToolMode.respond`
does.

- **`init`** lists `tools: ["WebSearch", "mcp__enigma__propose_edit"]` and
  the `enigma` SDK server as connected.
- **A search** is a `stream_event` `content_block_start` with a `tool_use`
  block named `WebSearch` (`input: {}`, then `input_json_delta`s), an
  `assistant` message with that block, then a `user` message whose
  `tool_use_result` is `{query, results, durationSeconds, searchCount}`.
- **Plain strings: yes, on every successful search.** `results` holds
  `{tool_use_id: "srvtoolu_…", content: [{title, url}]}` objects *and* a
  string: the search helper's prose summary of what it found.
- **A failed search is a bare string.** In latency question 1, 2 of the 4
  `WebSearch` calls failed: the model chose its own `allowed_domains` (the
  input also carried a `mode`), and `tool_use_result` was the string
  "Error: API Error: 400 The following domains are not accessible to our user
  agent: …", with the `tool_result` marked `is_error: true`. So
  `tool_use_result` can be a string after `.searchStarted` has fired. (The
  model choosing domains itself matters for F29's blocked sites.)
- **"Sources:" list.** 5 of 6 answers ended with one, beside inline
  Markdown links (3 to 17).
- **Haiku** thinks before and after searching; time to first text is long
  (see Q6).
- **Privacy.** The CLI's reply to `initialize` holds the account's email and
  organization; the fixtures replace them.
- **Decisions for CP5:**
  - `.toolsListed` from `init.tools`; `.searchStarted` on a
    `content_block_start` `tool_use` named `WebSearch`; `.searchResults`
    from the objects' `content[]` `{title, url}`.
  - Skip string entries, as the spec says. They're normal, not an edge
    case. Skip a `tool_use_result` that is itself a string (a failed
    search); the search still counts as started.
  - The cited sources are the answer's links; the closing "Sources:" text
    stays in the reply.
  - Never log the `initialize` reply.

### Q5: The restart

| Route | How | Delivered? | Stop took |
| --- | --- | --- | --- |
| Codex | The probe left `item/tool/call` unanswered and sent `turn/interrupt` | No: the `dynamicToolCall` item completed as `failed` with empty `contentItems`, then `turn/completed` `interrupted` | 0.11 s |
| Claude Code | Left the MCP `tools/call` unanswered and ended the process (SIGTERM, as F32's Stop) | No: the process exited (143) without a `result` line | 0.37 s |
| OpenAI, Anthropic | Not run (no key). A function call's result only reaches the provider in Enigma's next request, so not sending it, and cancelling the stream, delivers nothing by construction | — | — |

- **These show the providers can stop cleanly; they are not F32's
  behavior.** The probes never answered the call. F32's Codex path always
  answers it (see Q0), so CP4 must add the restart stop to
  `CodexToolMode.handle`/`Stop` and withhold the result before interrupting.
  On Claude Code, F32's `respond` already throws a terminal stop instead of
  answering and the client ends the process, which matches the probe once
  CP1's restart case exists.

### Q6: Latency

Brave: not measured (owner, 2026-10-29). Times run from the request
(`thread/start` for Codex on a running server; process launch for Claude
Code) to the first answer text, and to the end. "Sources" counts distinct discovered
URLs, before the cap of 8.

| # | Question |
| --- | --- |
| 1 | What are the top technology news headlines today? Link your sources. |
| 2 | What is the current US federal funds target rate range? Link your source. |
| 3 | In the current Python documentation, what does the `strict` parameter of `zip()` do, and since which version? Link the docs. |
| 4 | What do recent reviews say about the Sony WH-1000XM6 headphones? Link your sources. |
| 5 | When is the next total solar eclipse visible from Europe? Link your source. |

| Route | Q1 | Q2 | Q3 | Q4 | Q5 |
| --- | --- | --- | --- | --- | --- |
| Codex, gpt-5.6-luna (searches; first text / total; sources) | 3; 12.5 / 16.1 s; 110 | 1; 4.7 / 5.1 s; 18 | 1; 4.1 / 4.6 s; 12 | 4; 15.8 / 19.6 s; 41 | 1; 4.1 / 4.3 s; 28 |
| Claude Code, haiku | 4 (2 failed); 22.2 / 26.3 s; 18 | 2; 20.1 / 22.1 s; 20 | 1; 10.2 / 12.1 s; 10 | 2; 10.8 / 14.9 s; 17 | 1; 12.7 / 14.1 s; 10 |
| OpenAI, Anthropic | Not measured (no key) | | | | |

1. **Summary:** CP0 checked F32's names (all present) and answered Q1–Q6.
   ChatGPT (Codex) and Claude Code were probed live on the owner's sign-ins
   (gpt-5.6-luna; Claude Code with `haiku`, owner's choice). OpenAI and
   Anthropic weren't: the owner has no API key for either, so Q1 and Q2 come
   from the providers' docs and their fixtures are synthetic. The Codex
   thread setting works as the spec hoped; Claude Code's results routinely
   include plain strings; the restart delivers nothing on both subscription
   routes. No product code.
2. **Files:**
   - `EnigmaTests/Fixtures/CloudSearch/README.md`: one line per fixture.
   - `codex-web-search.jsonl`, `codex-search-and-dynamic-tool.jsonl`:
     recorded, scrubbed.
   - `claude-code-web-search.jsonl`: recorded, scrubbed;
     `claude-code-init-without-websearch.jsonl`: derived from it.
   - `openai-search-and-function.sse`, `openai-multi-search.sse`,
     `openai-replay-request.json`, `anthropic-search-and-tool.sse`,
     `anthropic-step-replay-request.json`, `anthropic-pause-turn.sse`,
     `anthropic-pause-continuation.sse`: synthetic, from the docs.
   - This brief's Hand-off, and the plan's progress-log row.
   - Not written (no key, and the docs give no bodies to copy):
     `openai-invalid-tool-error.json`, `openai-model-error.json`,
     `anthropic-blocked-domains-error.json`,
     `anthropic-tool-version-error.json`,
     `anthropic-search-disabled-error.json`. CP2 and CP3 build their error
     cases inline in tests, from the rules in Q1 and Q2.
3. **Decisions:**
   - Claude Code ran with `haiku` instead of the default `sonnet` (owner).
   - Brave latency not measured (owner).
   - OpenAI and Anthropic answered from docs, fixtures synthetic (owner has
     no keys). Per the plan's Global Constraints, `.openAI` and `.anthropic`
     stay out of `nativeWebSearchProviders` until someone with a key runs
     CP2's and CP3's live checks.
   - Codex probes used F32's tool-mode server settings (`fileMode`, so
     `features.code_mode_host=true`), as `submitNative` uses `fileCodex`.
4. **Verification:**
   - Q0: `grep -rlF` for each name over `Enigma/` and `EnigmaTests/`;
     `codex app-server generate-json-schema --experimental` on the installed
     0.164.0.
   - Live, run by the worker with the owner's approval (2026-10-29): Codex
     `configRequirements/read` and 10 turns (runs 1, 2, 5, 6, the restart, 5
     latency questions); Claude Code 7 runs (multi-search, the restart, 5
     latency questions).
   - Owner-run API probes: not run (no keys).
   - Fixtures: scrubbed by script (values and object keys; Claude Code's
     `rate_limit_event` dropped; Codex thread times zeroed), then checked
     with `grep` for the owner's name, email, home path, `toolu_`/`srvtoolu_`
     and other raw IDs, and usage data (none); every synthetic SSE `data:`
     line parses as JSON.
   - Review round 1 (Opus, xhigh): six Should-fix findings, all fixed: the
     restart path through F32's code (Q0, Q5), the `web_search_call` replay
     schema (Q1), the Anthropic fixtures' callers and the documented
     programmatic-tool-calling models (Q2), scrub misses, the failed
     `WebSearch` shape (Q4), and a local path in this brief.
   - Review round 2 (Opus, xhigh): no Blocker; five small Should-fix
     findings, all wording in this Hand-off, fixed by the worker without a
     third round (owner's rule): OpenAI forcing is documented (Q1), the
     replay candidates (Q1), `excluded` hiding the searching signal (Q2,
     owner decision), which Messages errors are terminal (Q0), and an empty
     `allowedWebSearchModes` list (Q3).
   - No Swift or script changes, so no build or test run (docs and fixtures
     only).
5. **Limitations:**
   - **OpenAI and Anthropic are unverified.** Every Q1/Q2 answer marked "not
     documented" or "unverified" is a guess CP2/CP3 must treat as one, and
     their live checks are needed before either provider turns on.
   - **Owner decisions (2026-10-29):** Anthropic uses
     `response_inclusion: "full"` (Q2). OpenAI sends no `user_location`, as
     the spec says, and accepts its US default (Q1).
   - **Found outside F30's scope:** F32's Anthropic loop sends
     `tool_choice: {"type": "tool", "name": …}` on step 1 for a required tool
     (typed `/search`, `/edit`), and Anthropic documents a 400 for that on
     Opus 5.5, Sonnet 5.5, Fable 5.1 and Mythos 5.1. Those commands likely
     fail on those models today. Proposed to the owner as a separate fix.
   - Codex: no disallowed-mode error and no `openPage` action were seen.
   - Claude Code's `init` lists the user's own plugins (one from
     `~/.claude/plugins`) despite `--safe-mode`; F32 behavior, not F30's,
     noted for the owner.
   - Each Codex thread logs that `tools.view_image` is ignored: F32's
     override is stale on 0.164.0.
   - Latency is one run per question, on one evening's network.
6. **For the next checkpoint:**
   - CP1: track "the reply started" as the first `.token` or tool call, not
     `acceptNative` (Q0). The restart goes through a new `AgentToolStop`
     case and a terminal result, not a thrown error (Q0).
   - CP2/CP3: build from Q1/Q2 and the synthetic fixtures. OpenAI: force
     `/search` with `allowed_tools` (mode `required`, `web_search` only) if
     the live check confirms it, else the instruction; replay follows the
     three candidates in Q1. Anthropic: never force `web_search` with
     `tool_choice`; replay sends every block unchanged, and a mixed turn can
     leave a `server_tool_use` without a result for the next request to
     run.
   - CP3: `response_inclusion: "full"` (owner), so the nested
     `server_tool_use`/`web_search_tool_result` pairs arrive, each with a
     `caller`, inside code execution; record that stream in the live check. Every model in the spec's
     prefix list supports programmatic tool calling, so keep the default
     callers there; the code-execution stream is unfixtured until CP3's live
     check records it.
   - CP4: see Q3's decisions; `results` entries are `text_result` objects;
     the restart needs a Codex-specific stop (Q0, Q5).
   - CP5: see Q4's decisions; string results are normal, and a failed
     search's whole `tool_use_result` is a string; never log the
     `initialize` reply.
   - The probes, scrubbers and raw recordings are in a scratch folder
     outside the repository and aren't committed. The OpenAI and Anthropic
     probes were written but never run; the probe requests are described
     in Tasks 0.2 and 0.3 above.
