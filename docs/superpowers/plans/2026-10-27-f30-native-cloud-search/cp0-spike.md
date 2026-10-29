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
| Q0 | F32 names on `main` | | | |
| Q1 | OpenAI: events beside functions, links, `max_tool_calls`, forced choice, replay, errors | | | |
| Q2 | Anthropic: events, step replay, budget, `pause_turn`, forced choice, blocked-domains limit, prefixes, errors | | | |
| Q3 | Codex: thread setting with dynamic tools, `allowedWebSearchModes`, events, links | | | |
| Q4 | Claude Code: `init` list, events, "Sources:" list, plain-string results | | | |
| Q5 | The restart on each route | | | |
| Q6 | Latency per route | | | |

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
