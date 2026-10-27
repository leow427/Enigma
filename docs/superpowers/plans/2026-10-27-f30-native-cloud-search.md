# Native web search for cloud models (F30) — implementation plan

This plan drives **F30** in `to-do.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to build your checkpoint yourself, task by task. Steps use checkbox (`- [ ]`) syntax for tracking. Here, each checkpoint is one worker's job, in a chat the owner starts; the worker starts its own reviewers. Read [agent-workflow.md](2026-10-27-f30-native-cloud-search/agent-workflow.md), then your checkpoint's brief. They and the spec are all you need.

**Goal:** OpenAI, Anthropic, ChatGPT (Codex) and Claude Code models answer
search requests with their provider's own web search. F29's on-device search
is the fallback.

**Architecture:**

1. `ChatRequest` gains an optional `CloudWebSearch`.
2. When a cloud request would search, `NativeWebSearch.decide` chooses
   between provider search and on-device search.
3. For provider search, `LocalChatViewModel` streams the request with that
   field set, and runs no on-device search.
4. Each provider client then:
   - turns on its own search tool and adds the search instruction;
   - reports searches, results and the chosen sources through the existing
     `ChatEvent.activity` events.
5. A client whose search isn't available throws
   `CloudProviderError.webSearchUnavailable` before replying. The request
   then continues on the on-device path.

**Tech Stack:**

- Swift 6 and SwiftUI on macOS 26.0;
- server-sent events through `ServerSentEventParser`;
- the Codex app server (JSON-RPC over stdio, pinned 0.164.0);
- the Claude Code CLI (`stream-json`);
- Python 3, standard library only, for the evaluation script;
- XCTest.

**Spec:** [2026-10-27-f30-native-cloud-search-design.md](../specs/2026-10-27-f30-native-cloud-search-design.md),
approved by the owner on 2026-10-27. Every agent reads it in full. This plan
doesn't repeat its reasoning.

**Prerequisite:** F29 is merged to `main`. F30 builds on F29's routing,
limits, blocked sites, on-device provider and evaluation tools.

## Global Constraints

- **Platform.** macOS 26.0 deployment target, Swift 6 strict concurrency, and
  the rules in `AGENTS.md`.
- **Dependencies.** No new Swift package, binary framework or Python package.
- **F29 names.** This plan uses these names from F29's plan:
  - `SearchRouting.decide(question:)` and `SearchRoute`;
  - `WebSearchLimits.maximumSources`;
  - `WebSearchSettings.blockedSites` (stored oldest first);
  - `OnDeviceSearchProvider`;
  - `scripts/web-search-queries.json` and `scripts/evaluate-web-search.py`.

  CP0 checks each against `main`. Where F29 shipped a different name, follow
  the code, and record the mapping in CP0's Hand-off.
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
  | Sources shown and saved | At most `WebSearchLimits.maximumSources` (8) |
  | Blocked sites named in the instruction | At most 20, most recent first |
  | Anthropic continuations after `pause_turn` | At most 3 |
  | Anthropic tool | `web_search_20260318` with `max_uses: 5` and `response_inclusion: "excluded"` for the reviewed model prefixes; `web_search_20250305` with `max_uses: 5` otherwise |
  | OpenAI fields | `tools: [{"type": "web_search"}]`, `include: ["web_search_call.action.sources"]`, `max_tool_calls: 5` |
  | Codex | `config.web_search` is `"live"`, or `"cached"` when the workspace policy allows only that |
  | Claude Code | `--tools WebSearch --allowedTools WebSearch` |

- **Privacy:**
  - No location ever reaches a provider's search: no `user_location`, and
    no Codex `tools.web_search.location`.
  - Screen, selection, places and weather turns never use provider search.
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
  - Tests are offline and deterministic. Network tests run only behind
    `ENIGMA_NATIVE_SEARCH_LIVE` or `ENIGMA_SEARCH_EVAL`.
  - Never delete, disable or weaken a test.
  - Tests that cover on-device search on cloud routes pass
    `nativeWebSearchProviders: []` (CP1), so they keep covering it after
    providers turn on.
- **Copy:** use the spec's exact strings: the search instruction and the
  prompt replacements (§3), the unavailable message (§1), and the Settings
  text (§6).
- **Git:** each worker commits its checkpoint once, after the last review
  round, on `feat/f30-native-cloud-search`, then logs it. No other git operations
  and no attribution lines anywhere.

## Review Focus

Five inputs the spec implies but doesn't spell out, most likely first. Each
is pinned by a test in the checkpoint that owns the code:

1. **A search with no citations, or the same page cited many times**, with
   different fragments or as both a citation and a link.
   - **Expected:** the sources fall back to the discovered results when
     nothing is cited, and the list has no duplicates.
   - **Pinned by:** CP1 `testSelectSourcesFallsBackToDiscoveredWhenNothingCited`
     and `testSelectSourcesDropsFragmentDuplicates`.
2. **Odd URLs from a provider:** `javascript:` links, credentials in a URL,
   relative paths, results without a URL.
   - **Expected:** they're dropped, never shown or saved.
   - **Pinned by:** CP1 `testSelectSourcesDropsUnsafeLinks`, CP4
     `testMalformedSearchResultsAreSkipped` and CP5
     `testParserSkipsMalformedSearchResults`.
3. **Stop while the provider is still searching,** before its first event.
   - **Expected:** nothing is added to the chat, `onAccepted` never runs so
     the draft stays, and the provider's request is cancelled.
   - **Pinned by:** CP1 `testStopBeforeFirstNativeEventAppendsNothing`.
4. **An "unavailable" error after the reply has started.**
   - **Expected:** no fallback and no second request. The error is shown,
     and the text and sources so far are kept.
   - **Pinned by:** CP1 `testUnavailableAfterFirstEventDoesNotFallBack`.
5. **A user with hundreds of blocked sites.**
   - **Expected:** the instruction names only the 20 most recent, and
     Anthropic gets at most its API limit.
   - **Pinned by:** CP1 `testInstructionNamesAtMostTwentyBlockedSites` and
     CP3 `testAnthropicSearchSendsBlockedDomainsWithinLimit`.

---

## How this plan runs

The rules every agent follows are in
[agent-workflow.md](2026-10-27-f30-native-cloud-search/agent-workflow.md).
In short, for each checkpoint in order:

1. **Worker.** The owner starts a fresh chat with a worker (Opus, medium
   effort) and points it at the checkpoint's brief. The worker builds it test-first,
   runs the exit checks, and fills in the brief's **Hand-off** section.
2. **Reviewer.** The worker starts a fresh reviewer agent (Opus, extra
   high effort) with `docs/reviewer.md`, the workflow's reviewer rules and
   the brief's checklist.
3. **Fixes.** The same worker fixes every Blocker and Should fix. A new
   reviewer runs each round, until a round has neither.
4. **Commit.** The worker reruns the exit checks, commits
   `<summary> (F30 CPn)` on `feat/f30-native-cloud-search`, pushes the
   branch, and updates the progress log below. It then reports to the owner, and the
   next checkpoint starts in a new chat.

The next checkpoint starts only after that commit. These stop the line until
the owner decides:

- a live run the owner hasn't approved;
- a failed quality gate (CP6);
- a spec conflict;
- a needed dependency.

## Checkpoints

| Checkpoint | Brief | Depends on | Produces |
| --- | --- | --- | --- |
| CP0 | [Spike](2026-10-27-f30-native-cloud-search/cp0-spike.md) | F29 merged | Answers to the spec's 7 open questions, the F29 name check, scrubbed fixtures |
| CP1 | [Shared plumbing](2026-10-27-f30-native-cloud-search/cp1-shared-plumbing.md) | CP0 | `CloudWebSearch`, the unavailable error, `NativeWebSearch` and its source collector, the view model's provider-search path with fallback; no provider on yet |
| CP2 | [OpenAI](2026-10-27-f30-native-cloud-search/cp2-openai.md) | CP1 | OpenAI request, stream and error mapping; the live-test file; `.openAI` on |
| CP3 | [Anthropic](2026-10-27-f30-native-cloud-search/cp3-anthropic.md) | CP2 | Tool by model, blocked domains, stream and citations, `AnthropicTurnAccumulator` and `pause_turn`, error mapping; `.anthropic` on |
| CP4 | [ChatGPT (Codex)](2026-10-27-f30-native-cloud-search/cp4-chatgpt-codex.md) | CP3 | Thread setting, policy check, `webSearch` events, answer links, error mapping; `.chatGPT` on |
| CP5 | [Claude Code](2026-10-27-f30-native-cloud-search/cp5-claude-code.md) | CP4 | Arguments, system prompt, parser events, `init` check; `.claudeCode` on |
| CP6 | [Quality check, docs and audit](2026-10-27-f30-native-cloud-search/cp6-quality-docs-audit.md) | CP5 | The comparison and its report, the Settings text, docs, `to-do.md`, final audit and merge |

## Interface map

Names every checkpoint shares. A brief's **Interfaces** blocks give the full
signatures. When a name or type changes, update this table and the briefs
that use it.

| Name | File | Defined in | Used in |
| --- | --- | --- | --- |
| `CloudWebSearch`, `ChatRequest.webSearch` | `Enigma/Chat/ChatDomain.swift` | CP1 | CP2–CP6 |
| `CloudProviderError.webSearchUnavailable(_:)` | `Enigma/Cloud/CloudDomain.swift` | CP1 | CP2–CP5 |
| `CloudProviderID.nativeWebSearchProviders`, `.supportsNativeWebSearch` | `Enigma/Cloud/CloudDomain.swift` | CP1 (empty) | CP2–CP6 |
| `NativeWebSearch` (`maximumSearches`, `maximumNamedBlockedSites`, `instructions(blockedDomains:namesBlockedDomains:)`, `decide(...)`, `selectSources(cited:linked:discovered:)`, `links(in:)`) | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP2–CP6 |
| `NativeWebSearchSources` (the per-request source collector) | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP2–CP5 |
| `NativeWebSearchAvailability` | `Enigma/Cloud/NativeWebSearch.swift` | CP1 | CP1 |
| `LocalChatViewModel.init(nativeWebSearchProviders:)` | `Enigma/LocalInference/LocalChatViewModel.swift` | CP1 | CP1–CP6 tests |
| `CloudSearchFixture`, `ScriptedCloudProvider` (tests) | `EnigmaTests/CloudSearchTestSupport.swift` | CP1 | CP1–CP6 tests |
| `NativeWebSearchLiveTests`, `EnvironmentCredentials` (tests) | `EnigmaTests/NativeWebSearchLiveTests.swift` | CP2 | CP3–CP6 |
| `OpenAIResponsesClient.webSearchFields(_:)`, `.isWebSearchRejection(statusCode:body:)` | `Enigma/Cloud/CloudProviderClients.swift` | CP2 | CP2 |
| `AnthropicMessagesClient.webSearchTool(modelID:blockedDomains:)`, `.dynamicSearchModelPrefixes`, `.maximumBlockedDomains`, `.maximumContinuations`, `.isWebSearchRejection(statusCode:body:)` | `Enigma/Cloud/CloudProviderClients.swift` | CP3 | CP3 |
| `AnthropicTurnAccumulator` | `Enigma/Cloud/AnthropicTurnAccumulator.swift` | CP3 | CP3 |
| `CodexSubscriptionClient.threadParameters(model:webSearch:searchMode:)`, `.webSearchMode(requirements:)` | `Enigma/Cloud/CodexSubscriptionClient.swift` | CP4 | CP4 |
| `ClaudeCodeRuntime.chatArguments(model:effort:streamsInput:webSearch:)`, `.searchSystemPrompt`, `ClaudeCodeStreamParser.Event.toolsListed/.searchStarted/.searchResults` | `Enigma/Cloud/ClaudeCodeSubscriptionClient.swift` | CP5 | CP5 |
| `NativeWebSearchEvaluationTests`; `evaluate-web-search.py --compare` | `EnigmaTests/NativeWebSearchEvaluationTests.swift`, `scripts/evaluate-web-search.py` | CP6 | CP6 |

**Where this plan refines the spec's names:**

- **The provider set.** `CloudProviderID.supportsNativeWebSearch` is backed
  by a set, `nativeWebSearchProviders`, which tests can replace through the
  view model's initializer.
- **Blocked sites.** The Codex and Claude Code functions take the
  `CloudWebSearch` itself (`webSearch:`) rather than a yes-or-no flag, so
  they carry the blocked sites.
- **The collector.** `NativeWebSearchSources` keeps the four clients from
  repeating the source bookkeeping.

The spec was updated to match on 2026-10-27.

## Progress log

Each worker updates this table after its checkpoint's commit. The worker's full
hand-off note stays in its brief.

| Checkpoint | Status | Commit | Review rounds | Notes |
| --- | --- | --- | --- | --- |
| CP0 | not started | | | |
| CP1 | not started | | | |
| CP2 | not started | | | |
| CP3 | not started | | | |
| CP4 | not started | | | |
| CP5 | not started | | | |
| CP6 | not started | | | |
