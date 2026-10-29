# Native web search for cloud models (F30) — implementation plan

This plan drives **F30** in `to-do.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to build your checkpoint yourself, task by task. Steps use checkbox (`- [ ]`) syntax for tracking. Here, each checkpoint is one worker's job, in a chat the owner starts; the worker starts its own reviewers. Read [agent-workflow.md](2026-10-27-f30-native-cloud-search/agent-workflow.md), then your checkpoint's brief. They and the spec are all you need.

**Goal:** On OpenAI, Anthropic, ChatGPT (Codex) and Claude Code, a flagged
cloud model searches with its provider's own search tool, with no Brave key,
in chats that hold no message text. Enigma's `web_search` covers the rest.

**Architecture:**

1. `NativeToolPlan` gains a search backend: `.provider` when
   `NativeWebSearch.isAllowed` says so, `.enigma` (F32's `WebSearchTool`)
   otherwise.
2. For `.provider`, `submitNative` sets `ChatRequest.providerSearch` and
   puts `ProviderSearchPart` (instructions only) in the toolbox instead of
   `WebSearchTool`.
3. Each provider's tool loop (`CloudToolCalling.swift`) adds its own search
   tool beside F32's function tools, and reports searches and sources
   through the existing `ChatEvent.activity` events.
4. A provider whose search isn't available throws
   `CloudProviderError.webSearchUnavailable` before the reply starts; the
   turn runs again with the plan made again.
5. If a Messages tool is about to return message text into a
   provider-search request, the gate holds the result back and raises
   `ProviderSearchRestart`; the turn runs again without provider search.

**Tech Stack:**

- Swift 6 and SwiftUI on macOS 26.0;
- F32's streaming tool loops (`CloudToolLoop`, the per-provider
  `ToolStreamAssembler`s) over server-sent events;
- the Codex app server (JSON-RPC over stdio, F32's `CodexToolMode` with
  dynamic tools);
- the Claude Code CLI (`stream-json`, F32's `ClaudeCodeToolMode` with an SDK
  MCP server);
- Python 3, standard library only, for the comparison script;
- XCTest.

**Spec:** [2026-10-27-f30-native-cloud-search-design.md](../specs/2026-10-27-f30-native-cloud-search-design.md),
revised and approved by the owner on 2026-10-29. Every agent reads it in
full. This plan doesn't repeat its reasoning.

**Prerequisite:** F32 is on `main` (merged 2026-10-29). F30 runs before
F29, so nothing here may assume F29's names: no `SearchRouting`, no
on-device provider, no blocked-sites list.

## Global Constraints

- **Platform.** macOS 26.0 deployment target, Swift 6 strict concurrency, and
  the rules in `AGENTS.md`.
- **Dependencies.** No new Swift package, binary framework or Python package.
- **F32 names.** This plan uses these names from F32:
  - `NativeToolPlan`, `NativeToolPart`, `AssistantToolbox`, `AgentToolbox`;
  - `WebSearchTool` (`Enigma/Search/WebSearchTool.swift`);
  - `LocalChatViewModel.submitNative`, `nativeToolPlan(for:)`,
    `SavingMessagesGate`, `messageTextMayGo(to:)`;
  - `ChatSession.holdsMessageText`;
  - `CloudToolLoop`, `ToolStreamAssembler`, `OpenAIToolStreamAssembler`,
    `AnthropicToolStreamAssembler`, `CodexToolMode`, `ClaudeCodeToolMode`;
  - `CloudModelCapabilities.supportsNativeTools`;
  - `NativeToolsEvalTests`, `EnvironmentCredentials`,
    `EnigmaTests/Fixtures/F32/eval.jsonl`.

  CP0 checks each against `main`. Where the code differs, follow the code,
  and record the mapping in CP0's Hand-off.
- **Turning providers on.**
  - `CloudProviderID.nativeWebSearchProviders` is `[]` after CP1.
  - CP2 adds `.openAI`, CP3 `.anthropic`, CP4 `.chatGPT` and CP5
    `.claudeCode`, each only after its live check passes.
  - A provider whose account the owner can't provide stays off, and the
    Hand-off says so.
  - `.gemini` is never added.
  - CP6's quality gate decides which stay on when the branch merges.
- **Values:**

  | What | Value |
  | --- | --- |
  | `NativeWebSearch.maximumSearches` | 5 |
  | Sources shown and saved | At most 8, as `NativeWebSearch.maximumSources` (F29 later sets `WebSearchLimits.maximumSources` to the same 8; Brave's own cap stays 10) |
  | Restarts per turn | At most 1 |
  | Anthropic continuations after `pause_turn` | At most 3 per step, outside F32's 12-step limit |
  | Anthropic tool | `web_search_20260318` with `max_uses: 5` and `response_inclusion: "full"` (owner, 2026-10-29) for the reviewed model prefixes; `web_search_20250305` with `max_uses: 5` otherwise |
  | OpenAI fields | `{"type": "web_search"}` in `tools`, `include: ["web_search_call.action.sources"]`, `max_tool_calls: 5` if CP0 confirms it counts only built-in calls |
  | Codex | `config.web_search` is `"live"`, or `"cached"` when the workspace allows only that |
  | Claude Code | `--tools WebSearch`, and `WebSearch` in `--allowedTools` beside F32's MCP tool names |

- **Privacy:**
  - No location ever reaches a provider's search: no `user_location`, and
    no Codex `tools.web_search.location`.
  - No provider search in a chat that holds message text, and no message
    text in a provider-search request: the restart (spec §2) is enforced in
    the gate, in Swift.
  - Claude Code's `WebFetch` stays off.
  - Logs name the provider and the event, never a query, URL or answer text.
  - Nothing new is written to disk. Availability marks live in memory only.
- **Accounts and money:**
  - Probes, live checks and the evaluation use the owner's accounts. Before
    each batch of live runs (CP0, each live check, CP6), the worker gets
    the owner's approval with an estimate of the searches.
  - API keys reach only commands the owner runs, through environment
    variables. Agents never read a key from the Keychain, print one, or write
    one to a file.
- **Tests:**
  - Offline and deterministic. Network tests run only behind
    `ENIGMA_NATIVE_SEARCH_LIVE` or `ENIGMA_SEARCH_EVAL`.
  - Never delete, disable or weaken a test.
  - Tests that cover Enigma's `web_search` on cloud routes pass
    `nativeWebSearchProviders: []` (CP1), so they keep covering it after
    providers turn on.
  - F32's `NativeToolRequestTests` and `CloudToolStreamingTests` stay green
    unchanged; F30 adds to them.
- **Copy:** use the spec's exact strings: the search instruction (§4), the
  unavailable message (§6), and the docs' wording (Docs).
- **Git:** each worker commits its checkpoint once, after the last review
  round, on `feat/f30-native-cloud-search`, with its progress-log row in the
  same commit. No other commits or git operations, and no attribution lines
  anywhere.

## Review Focus

Six inputs the spec implies but doesn't spell out, most likely first. Each
is pinned by a test in the checkpoint that owns the code:

1. **The model reads a chat partway through a provider-search reply,**
   after it has already searched and written some text.
   - **Expected:** the read's result never reaches the provider; the reply
     on screen restarts; the second run has `.enigma` search behind gate 3
     (or none without a Brave key); the read isn't asked again; it happens
     once.
   - **Pinned by:** CP1 `testMessageTextHoldsResultAndRestarts`,
     `testRestartRunsOnceWithoutProviderSearch` and
     `testRestartKeepsTheReadGrant`; CP2–CP5 each
     `test<Provider>RestartDeliversNothing`.
2. **A chat reopened from Recents that holds message text.**
   - **Expected:** no provider search on any route; Enigma's `web_search`
     behind gate 3 if a Brave key is saved, otherwise no search.
   - **Pinned by:** CP1 `testChatHoldingMessageTextNeverGetsProviderSearch`.
3. **A search with no citations, or the same page cited many times**, with
   different fragments or as both a citation and a link.
   - **Expected:** the sources fall back to the discovered results when
     nothing is cited, and the list has no duplicates.
   - **Pinned by:** CP1 `testSelectSourcesFallsBackToDiscoveredWhenNothingCited`
     and `testSelectSourcesDropsFragmentDuplicates`.
4. **Odd URLs from a provider:** `javascript:` links, credentials in a URL,
   relative paths, results without a URL.
   - **Expected:** they're dropped, never shown or saved.
   - **Pinned by:** CP1 `testSelectSourcesDropsUnsafeLinks`, CP4
     `testMalformedSearchResultsAreSkipped` and CP5
     `testParserSkipsMalformedSearchResults`.
5. **An "unavailable" error after the reply has started.**
   - **Expected:** no fallback and no second run. The error is shown, and
     the text and sources so far are kept.
   - **Pinned by:** CP1 `testUnavailableAfterReplyStartsDoesNotFallBack`.
6. **Stop during a restart,** after the first run stopped and before the
   second sends anything.
   - **Expected:** the turn ends like any Stop; no second request goes out.
   - **Pinned by:** CP1 `testStopDuringRestartEndsTheTurn`.

---

## How this plan runs

The rules every agent follows are in
[agent-workflow.md](2026-10-27-f30-native-cloud-search/agent-workflow.md).
In short, for each checkpoint in order:

1. **Worker.** The owner starts a fresh chat with a worker (Opus, medium
   effort) and points it at the checkpoint's brief. The worker builds it
   test-first, runs the exit checks, and fills in the brief's **Hand-off**
   section.
2. **Reviewer.** The worker starts a fresh reviewer agent (Opus, extra high
   effort) with `docs/reviewer.md`, the workflow's reviewer rules and the
   brief's checklist.
3. **Fixes.** The same worker fixes every Blocker and Should fix. A new
   reviewer runs each round, until a round has neither, for at most three
   rounds.
4. **Commit.** The worker reruns the exit checks, commits
   `<summary> (F30 CPn)` on `feat/f30-native-cloud-search`, with the
   progress log below updated in the same commit, pushes the branch and
   checks CI. It then reports to the owner, and the next checkpoint starts
   in a new chat.

These stop the line until the owner decides:

- a live run the owner hasn't approved;
- a failed quality gate (CP6);
- a spec conflict;
- a needed dependency.

## Checkpoints

| Checkpoint | Brief | Depends on | Produces |
| --- | --- | --- | --- |
| CP0 | [Spike](2026-10-27-f30-native-cloud-search/cp0-spike.md) | F32 on `main` | Answers to the spec's 6 open questions, the F32 name check, scrubbed fixtures, the worktree |
| CP1 | [Shared plumbing](2026-10-27-f30-native-cloud-search/cp1-shared-plumbing.md) | CP0 | `NativeWebSearch` and its helpers, the plan's search backend, `ChatRequest.providerSearch`, fallback, the restart, sources, the draft PR; no provider on yet |
| CP2 | [OpenAI](2026-10-27-f30-native-cloud-search/cp2-openai.md) | CP1 | OpenAI's search tool in the tool loop, stream, replay, error mapping; the live-test file; `.openAI` on |
| CP3 | [Anthropic](2026-10-27-f30-native-cloud-search/cp3-anthropic.md) | CP2 | Tool by model, stream and citations, server-block replay, `pause_turn`, error mapping, output margin; `.anthropic` on |
| CP4 | [ChatGPT (Codex)](2026-10-27-f30-native-cloud-search/cp4-chatgpt-codex.md) | CP3 | Thread setting with dynamic tools, policy check, `webSearch` events, answer links, error mapping; `.chatGPT` on |
| CP5 | [Claude Code](2026-10-27-f30-native-cloud-search/cp5-claude-code.md) | CP4 | Arguments beside the MCP tools, parser events, `init` check; `.claudeCode` on |
| CP6 | [Quality check, docs and audit](2026-10-27-f30-native-cloud-search/cp6-quality-docs-audit.md) | CP5 | The eval and comparison, the report, docs, `to-do.md`, final audit and merge |

## Interface map

Names every checkpoint shares. A brief's **Interfaces** blocks give the full
signatures. When a name or type changes, update this table and the briefs
that use it.

| Name | File | Defined in | Used in |
| --- | --- | --- | --- |
| `ProviderSearch`, `ChatRequest.providerSearch` | `Enigma/Chat/ChatDomain.swift` | CP1 | CP2–CP6 |
| `SearchBackend`, `NativeToolPart.search(SearchBackend)`, `NativeToolPlan.Inputs.providerSearch` | `Enigma/Chat/AssistantToolbox.swift` | CP1 | CP1–CP6 |
| `CloudProviderError.webSearchUnavailable(_:)` | `Enigma/Cloud/CloudDomain.swift` | CP1 | CP2–CP5 |
| `CloudProviderID.nativeWebSearchProviders`, `.supportsNativeWebSearch` | `Enigma/Cloud/CloudDomain.swift` | CP1 (empty) | CP2–CP6 |
| `NativeWebSearch` (`maximumSearches`, `maximumSources`, `isAllowed(provider:modelID:holdsMessageText:availability:)`, `selectSources(cited:linked:discovered:)`, `links(in:)`) | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP2–CP6 |
| `ProviderSearchPart` (the instruction) | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP2–CP5 |
| `NativeWebSearchSources` (the per-request source collector) | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP2–CP5 |
| `NativeWebSearchAvailability` | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP1 |
| `ProviderSearchRestart` | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP1–CP5 |
| `LocalChatViewModel.init(nativeWebSearchProviders:)` | `Enigma/LocalInference/LocalChatViewModel.swift` | CP1 | CP1–CP6 tests |
| `CloudSearchFixture`, `ScriptedSearchProvider` (tests) | `EnigmaTests/CloudSearchTestSupport.swift` | CP1 | CP1–CP6 tests |
| `NativeWebSearchLiveTests` (tests) | `EnigmaTests/NativeWebSearchLiveTests.swift` | CP2 | CP3–CP6 |
| `OpenAIResponsesClient.webSearchFields(required:)`, `.isWebSearchRejection(statusCode:body:)` | `Enigma/Cloud/CloudToolCalling.swift` | CP2 | CP2 |
| `AnthropicMessagesClient.webSearchTool(modelID:blockedDomains:)`, `.dynamicSearchModelPrefixes`, `.maximumBlockedDomains`, `.maximumContinuations`, `.isWebSearchRejection(statusCode:body:)` | `Enigma/Cloud/CloudToolCalling.swift` | CP3 | CP3 |
| `CodexToolMode.threadParameters(model:toolbox:providerSearch:searchMode:)`, `CodexSubscriptionClient.webSearchMode(requirements:)` | `Enigma/Cloud/CloudToolCalling.swift`, `CodexSubscriptionClient.swift` | CP4 | CP4 |
| `ClaudeCodeSubscriptionClient` tool arguments with `providerSearch:`, `ClaudeCodeStreamParser.Event.toolsListed/.searchStarted/.searchResults` | `Enigma/Cloud/ClaudeCodeSubscriptionClient.swift` | CP5 | CP5 |
| `scripts/web-search-queries.json`, `scripts/search_judge.py`, `scripts/evaluate-native-search.py`, `NativeWebSearchEvaluationTests` | `scripts/`, `EnigmaTests/` | CP6 | CP6; F29 extends them |

**Where this plan refines the spec's names:**

- **The provider set.** `CloudProviderID.supportsNativeWebSearch` is backed
  by a set, `nativeWebSearchProviders`, which tests replace through the
  view model's initializer.
- **The collector.** `NativeWebSearchSources` keeps the four clients from
  repeating the source bookkeeping.
- **File placement.** The provider changes go where F32 put each route's
  tool loop (`CloudToolCalling.swift`) and assembler
  (`CloudToolStreaming.swift`), not in the plain clients.

## Progress log

Each worker updates its row in the checkpoint's own commit. There's no
commit column, since a commit can't name its own hash: find a checkpoint's
commit with `git log --grep "(F30 CP<N>)"`. The worker's full hand-off note
stays in its brief.

| Checkpoint | Status | Review rounds | Notes |
| --- | --- | --- | --- |
| CP0 | done | 2 | Codex and Claude Code probed live; OpenAI and Anthropic from docs (no keys), synthetic fixtures, stay off until a live check; owner decided (2026-10-29): Anthropic `response_inclusion: "full"`; OpenAI sends no `user_location`, as the spec says |
| CP1 | not started | | |
| CP2 | not started | | |
| CP3 | not started | | |
| CP4 | not started | | |
| CP5 | not started | | |
| CP6 | not started | | |
