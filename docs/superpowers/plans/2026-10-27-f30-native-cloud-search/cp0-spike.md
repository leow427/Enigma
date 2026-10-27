# CP0: Spike — answer the open questions

Read [agent-workflow.md](agent-workflow.md) and the spec in full. The spec's
"Open questions for CP0" list is this checkpoint's scope.

## Goal

Answer the spec's seven open questions with throwaway probes, and check
F29's names, so later checkpoints build on facts. **No product code comes
out of this checkpoint.**

- Probes live in a scratch folder outside the repository. Python 3
  (standard library) or `curl` suits the HTTP probes, and Python's
  `subprocess` suits the Codex app server and Claude Code.
- Only two things are committed: this brief's Hand-off with the findings,
  and the scrubbed fixtures with their README.

## Starting point

- **F29 is merged.** Brave is gone, and `OnDeviceSearchProvider` serves every
  route.
- **Cloud clients:**
  - `OpenAIResponsesClient` and `AnthropicMessagesClient` are in
    `Enigma/Cloud/CloudProviderClients.swift`;
  - `CodexSubscriptionClient` is in `CodexSubscriptionClient.swift`.
    `CodexAppServer.swift` holds `CodexAppServer`, the JSON-RPC process
    with the `initialize` handshake, and `CodexRuntimeConfiguration`, whose
    `live` value has the launch `arguments`, `environment(for:)` and the
    `CODEX_HOME` folder;
  - `ClaudeCodeSubscriptionClient`, `ClaudeCodeRuntime` and
    `ClaudeCodeStreamParser` are in `ClaudeCodeSubscriptionClient.swift`.
- **Facts already checked on 2026-10-27** (recheck only what's marked):
  - **Pinned Codex 0.164.0 schema,** generated with `codex app-server
    generate-json-schema --out <folder>`:
    - `ThreadStartParams.config` accepts any keys;
    - `TurnStartParams` has no `config`;
    - the `webSearch` thread item is `{id, query, action?, results?}`, where
      `action` is `search`, `openPage`, `findInPage` or `other`, and
      `results` is opaque JSON;
    - `WebSearchMode` is `disabled`, `cached`, `indexed` or `live`;
    - the requirements method is `configRequirements/read`;
    - citations appear only in experimental raw response items.
  - **Claude Code 2.1.311 on a subscription login:**
    - `-p --tools WebSearch --allowedTools WebSearch` searches with no
      prompt;
    - `init` lists `tools: ["WebSearch"]` and `apiKeySource: "none"`;
    - results arrive in a `user` message's
      `tool_use_result.results[].content[]` as `{title, url}`.
  - **Anthropic** (from its docs):
    - the tool shapes, the stream events, the `web_search_tool_result`
      error object, citations, and `pause_turn` ("send the paused assistant
      message back unchanged");
    - search costs $10 per 1,000 searches;
    - an organization admin can turn search off, which gives a 400.
  - **OpenAI** (from its docs):
    - the `web_search` tool, `include: ["web_search_call.action.sources"]`,
      and `url_citation` annotations (url, title, start and end index);
    - "inline citations must be made clearly visible and clickable";
    - the streaming event names weren't confirmed.

## Tasks

### Task 0.1: F29 names (Q0)

- [ ] **Check each name** in the plan's Global Constraints "F29 names" list
  against `main`, with `grep -rn`. Also check:
  - `WebSearchContext.prepare`'s current signature;
  - where F29's Settings note text lives (the `WebSearchSettingsSection`
    note);
  - whether a snapshot test covers it.
- [ ] **Record** each name as found, or its new name, in the findings table.

### Task 0.2: Codex (Q1, Q2)

**Approval needed:** the owner approves about 6 ChatGPT turns in the
chat.

- [ ] **Write the probe.** It starts the app server the way Enigma does:
  - the executable from `CodexRuntime.installedExecutable()`, which is the
    pinned 0.164.0 in Application Support;
  - the `CODEX_HOME` and `PATH` from
    `CodexRuntimeConfiguration.live.environment(for:)`;
  - every `-c` override in `CodexRuntimeConfiguration.live.arguments`,
    including `web_search="disabled"`.

  It then sends `initialize` and `initialized` (copy the handshake from
  `CodexAppServer`), `thread/start` and `turn/start`, and records every
  notification as JSONL.
- [ ] **Run these:**
  1. **Q1, the thread setting.** A thread whose `config` is
     `{"web_search": "live"}`, plus `CodexSubscriptionClient.threadParameters`'
     other fields, with the question "What is the latest stable Swift
     release? Answer in one sentence and link your source." Record whether
     any `webSearch` item appears.
  2. **The same question without `config`.** Confirm nothing is searched.
  3. **If run 1 didn't search,** try the two options in spec §2: launch
     without `web_search="disabled"` and send `"disabled"` or `"live"` per
     thread, or launch a second server with `web_search="live"`. Record
     which works.
  4. **`configRequirements/read`.** Record the response, and whether it
     contains `allowedWebSearchModes`.
  5. **Q2, a multi-search question:** "Compare the current prices of the
     cheapest MacBook Air and the cheapest MacBook Pro in the US. Link your
     sources." Record:
     - the `item/started` and `item/completed` order;
     - every `action` type;
     - what `results` holds;
     - whether the answer contains Markdown links.
- [ ] **Save the fixtures,** scrubbed, with thread and turn IDs set to
  `thread-one` and `turn-one`:
  - `codex-web-search.jsonl`, the notifications from run 5;
  - `codex-thread-start-error.json`, if any run produced a JSON-RPC error.

### Task 0.3: OpenAI (Q3)

**Owner-run.** Write `probe-openai.sh`, which reads `ENIGMA_OPENAI_KEY` from
the environment and writes raw output to a folder outside the repository.
Ask the owner to run it: about 4 requests and up to 15
searches.

- [ ] **The script's requests,** to the `/v1/responses` endpoint with
  `"stream": true` and `"store": false`:
  1. **Search on.** Model `gpt-5.6-luna` (or `ENIGMA_OPENAI_MODEL`), with
     spec §2's `tools`, `include` and `max_tool_calls: 5`. The question:
     "What is the latest stable Swift release? Link your source."
  2. **The multi-search question** from Task 0.2.
  3. **An invalid tool,** `{"type": "web_search", "search_context_size": "huge"}`,
     to capture a 400 that names `tools`.
  4. **An older model,** `gpt-4o-mini` with the same tools, to see whether
     it searches or rejects the tool.
- [ ] **From the recordings, answer Q3:**
  - the order of events with search, and the shapes of the
    `response.output_item.added` and `response.output_item.done` items for
    `web_search_call` and `message`;
  - whether `action.sources` has titles;
  - whether the `output_text` deltas already contain the cited links as
    Markdown, at the annotation ranges;
  - whether `max_tool_calls` is accepted;
  - the exact error JSON for request 3, and for request 4 if it fails.
- [ ] **Save the fixtures:**
  - `openai-web-search.sse`, from request 2;
  - `openai-invalid-tool-error.json`, from request 3;
  - `openai-model-error.json`, from request 4 if it failed.

### Task 0.4: Anthropic (Q4)

**Owner-run.** Write `probe-anthropic.sh`, which reads
`ENIGMA_ANTHROPIC_KEY`. About 12 requests and up to 30 searches.

- [ ] **The script's requests,** to the `/v1/messages` endpoint with
  `"stream": true`, `anthropic-version: 2023-06-01`, the model
  `claude-sonnet-4-6` (or `ENIGMA_ANTHROPIC_MODEL`), and `max_tokens` 4096:
  1. **The new tool.** `web_search_20260318` with `max_uses: 5` and
     `response_inclusion: "excluded"`, on the multi-search question.
  2. **The same, with `max_tokens` 1024,** to see whether search blocks
     count against it (`stop_reason: "max_tokens"` before any text).
  3. **A paused turn.** Try to cause `pause_turn` with "Find the current
     price of each of these 12 products and list them with sources: …" (12
     well-known products). If a pause comes, send the continuation:
     - first with the paused message's blocks;
     - and, if a second pause comes, with all blocks so far.

     Record what the API accepts.
  4. **Blocked domains.** `blocked_domains` lists of 10, 64, 100 and 500
     made-up domains (`blocked-0001.example`, …). Record the largest size
     accepted, and the error body above it.
  5. **The basic tool.** `web_search_20250305` on `claude-haiku-4-5`.
  6. **The new tool on an older model,** `web_search_20260318` on
     `claude-haiku-4-5`. Record the error JSON.
  7. **Each candidate prefix.** One request with `max_uses: 1` per model the
     owner's account can call, from `claude-opus-4-6`, `claude-sonnet-4-6`,
     `claude-opus-4-7`, `claude-opus-4-8`, `claude-opus-5`,
     `claude-opus-5-5`, `claude-sonnet-5`, `claude-sonnet-5-5`,
     `claude-fable-5`, `claude-fable-5-1` and `claude-haiku-5-5`. Record
     which accept `web_search_20260318`.
  8. **Organization off (optional).** If the owner is willing to turn search
     off for their organization in the Claude Console for a minute, record
     the 400 body. Otherwise use the docs' wording, and mark it as from the
     docs.
- [ ] **Answer Q4,** including the event order with code-execution blocks,
  and what `response_inclusion: "excluded"` leaves out.
- [ ] **Save the fixtures:**
  - `anthropic-web-search.sse`, from request 1;
  - `anthropic-pause-turn.sse` and `anthropic-pause-continuation.sse`, if a
    pause happened;
  - `anthropic-blocked-domains-error.json`;
  - `anthropic-tool-version-error.json`, from request 6;
  - `anthropic-search-disabled-error.json`, if recorded.

### Task 0.5: Claude Code (Q5)

**Approval needed:** about 3 Claude Code runs.

- [ ] **Run the multi-search question** with Enigma's search arguments: the
  arguments of `ClaudeCodeRuntime.chatArguments`, with `--tools WebSearch
  --allowedTools WebSearch` in place of `--tools ""`. Use the environment of
  `ClaudeCodeRuntime.live.environment` and an empty working folder.
- [ ] **Answer Q5:**
  - Does the answer end with a "Sources:" list?
  - Does `tool_use_result.results` ever hold plain strings?
  - Which partial-message events mark the start of a `WebSearch` call?
- [ ] **Save the fixtures:**
  - `claude-code-web-search.jsonl`, scrubbed of `session_id`, `uuid` and
    the account fields in `init`;
  - `claude-code-init-without-websearch.jsonl`, its `init` line with
    `tools: []`. Mark it **derived** in the README.

### Task 0.6: Compliance and latency (Q6, Q7)

**Owner-run and approved runs:** about 10 questions per route.

- [ ] **Choose 10 web questions** from F29's `scripts/web-search-queries.json`,
  across the news, facts, docs and reviews categories. List their IDs in the
  Hand-off.
- [ ] **For each route** (OpenAI, Anthropic, ChatGPT, Claude Code), record
  per question:
  - whether it searched;
  - the time to first text and the total time;
  - the number of sources.

  The API routes reuse the probe scripts, run by the owner. The subscription
  routes reuse Task 0.2's and Task 0.5's probes.
- [ ] **Take on-device latency** for comparison from F29's evaluation report
  in `docs/history/`.

## Exit criteria

- All eight rows of the findings table below are filled in, and every
  "owner decision needed" is marked.
- The fixtures and `EnigmaTests/Fixtures/CloudSearch/README.md` are saved,
  scrubbed per the workflow.
- No probe code or raw recording is left in the worktree.
- `git status` shows only this brief and the fixtures.

## Reviewer checklist

- **Check the fixtures** for anything the workflow says to scrub: IDs,
  emails, encrypted fields, keys. Also check that each README line matches
  its file.
- **Check each decision** follows from the recorded evidence. Q1's choice
  and Q4's prefix list matter most.
- **Never rerun a live probe.** Reason from the recordings.

## Hand-off

*Filled in by the CP0 worker.*

| # | Question | Answer | Evidence | Decision for later checkpoints |
| --- | --- | --- | --- | --- |
| Q0 | F29 names on `main` | | | |
| Q1 | Codex thread setting, and `allowedWebSearchModes` | | | |
| Q2 | Codex events, `results` and answer links | | | |
| Q3 | OpenAI events, inline links, `max_tool_calls`, error bodies | | | |
| Q4 | Anthropic events, budget, `pause_turn`, blocked-domains limit, prefixes, error bodies | | | |
| Q5 | Claude Code fixture, "Sources:" list, plain-string results | | | |
| Q6 | Compliance per route | | | |
| Q7 | Latency per route, against on-device | | | |

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
