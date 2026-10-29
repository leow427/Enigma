# CP4: ChatGPT (Codex) — live web search beside the dynamic tools

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "ChatGPT", §4,
§5), and the Hand-offs of [CP0](cp0-spike.md#hand-off) to
[CP3](cp3-anthropic.md#hand-off).

## Goal

A provider-search Codex thread asks for live web search beside F32's
dynamic tools, falls back to `cached` or unavailable under a workspace
policy, reports `webSearch` items as activity and sources, and takes its
cited sources from the answer's links. When the owner's live check passes,
`.chatGPT` joins the provider set.

## Starting point

- **`CodexToolMode`** (`CloudToolCalling.swift`):
  `threadParameters(model:toolbox:)` builds `thread/start` with
  `dynamicTools` and `developerInstructions`; `handle(method:params:toolbox:stop:)`
  answers dynamic tool calls. `CodexSubscriptionClient`'s
  `ToolCallingChatProvider` extension runs the turn.
- **`CodexAppServer.arguments`** launches with `-c web_search="disabled"`.
- **CP0's Q3:** whether the thread setting overrides the launch argument
  with dynamic tools present, `configRequirements/read`'s shape, the
  `webSearch` item order and `results`, whether answers carry links, and
  what a disallowed mode returns. **Q5:** how `turn/interrupt` behaves
  after a held-back dynamic tool call.

## Tasks

### Task 4.1: The thread setting and the policy

**Interfaces:**

```swift
extension CodexToolMode {
  static func threadParameters(model: String, toolbox: any AgentToolbox,
                               providerSearch: ProviderSearch?, searchMode: String?) throws -> CodexValue
}
extension CodexSubscriptionClient {
  /// "live", or "cached" when only that is allowed; nil when neither is.
  static func webSearchMode(requirements: CodexValue?) -> String?
}
```

- [ ] **Write the failing tests** in `CodexSubscriptionTests`:
  - `testCodexSearchThreadParameters`: `config: {"web_search": <mode>}`
    beside `dynamicTools`; the developer instructions' tools line gains
    "and web search" and the spec §4 instruction follows.
  - `testCodexThreadWithoutSearchUnchanged`.
  - `testCodexSearchThreadLocation` (spec §2a): with `providerSearch.location`,
    `config` also holds `tools.web_search.location` (`{city, region,
    country, timezone}`, missing parts left out); without it, no location
    key. Confirm the key with one approved ChatGPT turn before relying on it
    (the 0.164.0 schema has `WebSearchToolConfig.location`).
  - `testCodexWebSearchModeFromRequirements`: live allowed, only cached,
    neither, and no requirements.
  - `testCodexNoAllowedModeIsUnavailable`: neither mode allowed throws
    `.webSearchUnavailable(.chatGPT)` before `turn/start`.
  - If CP0 found the thread setting doesn't override the launch argument:
    `testCodexLaunchSetting` for the option CP0 chose (spec §3).
- [ ] **Run, implement, run.**

### Task 4.2: Events, links and errors

- [ ] **Write the failing tests:**
  - `testCodexWebSearchEventsFromFixture` (`codex-web-search.jsonl`):
    `.phase(.searching)` on `item/started`; `openPage` URLs and `results`
    objects as discovered sources; `.sourcesSelected` from the answer's
    links before `.completed`.
  - `testMalformedSearchResultsAreSkipped`: `results` entries without a
    string `url`, with `javascript:` URLs, or as plain strings are skipped.
  - `testCodexSearchAndDynamicToolTogether`
    (`codex-search-and-dynamic-tool.jsonl`): both run in one turn.
  - `testCodexThreadStartErrorIsUnavailable`, from CP0's error fixture or
    its recorded text.
  - `testCodexRestartDeliversNothing`: on `ProviderSearchRestart`, no
    dynamic tool response is sent and the turn is interrupted as CP0 Q5
    found.
- [ ] **Run, implement, run.**

### Task 4.3: The live check, and turning ChatGPT on

- [ ] **Add** `testChatGPTSearchesLive` to `NativeWebSearchLiveTests`: the
  Swift release question through the Mac's ChatGPT sign-in; a search, a
  safe source, an answer.
- [ ] **Get the owner's approval** (one or two turns), run it, record it.
- [ ] **When it passes,** add `.chatGPT` to the set and update the test.

## Exit criteria

- The touched classes pass; `build` and `analyze` succeed; the full `test`
  once before the commit; CI passes.
- The live check passed, or `.chatGPT` stays off and the Hand-off says why.

## Reviewer checklist

- The turn keeps F32's read-only sandbox and declined approvals; a
  location in `config` only from `providerSearch.location` (spec §2a), never
  coordinates.
- A thread without provider search is unchanged, including the launch
  arguments unless CP0 required otherwise.
- Malformed results never become sources.

## Hand-off

*Filled in by the CP4 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
