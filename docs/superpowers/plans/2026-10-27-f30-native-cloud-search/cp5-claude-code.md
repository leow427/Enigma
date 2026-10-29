# CP5: Claude Code — WebSearch beside the MCP tools

Read [agent-workflow.md](agent-workflow.md), the spec (§3 "Claude Code", §4,
§5), and the Hand-offs of [CP0](cp0-spike.md#hand-off) to
[CP4](cp4-chatgpt-codex.md#hand-off).

## Goal

A provider-search Claude Code request runs with `WebSearch` beside F32's MCP
tools, stops and falls back when a policy withholds it, reports its searches
and results, and takes its cited sources from the answer's links. When the
owner's live check passes, `.claudeCode` joins the provider set.

## Starting point

- **`ClaudeCodeSubscriptionClient`** (`ClaudeCodeSubscriptionClient.swift`)
  builds F32's tool-mode arguments: `--safe-mode`, `--tools ""`,
  `--strict-mcp-config`, `--mcp-config` with the SDK server,
  `--disable-slash-commands`, `--allowedTools` of the `mcp__…` names, and
  the system prompt from `ClaudeCodeToolMode.systemPrompt(toolbox)`.
- **`ClaudeCodeToolMode`** (`CloudToolCalling.swift`) answers MCP messages;
  its `stream` extension runs the process and maps control requests.
- **`ClaudeCodeStreamParser`** parses `stream-json`.
- **CP0's Q4:** the `init` tools list with `WebSearch` and MCP tools, the
  search events, any "Sources:" list, and plain-string results. **Q5:**
  ending the process after a held-back `tools/call`.

## Tasks

### Task 5.1: Arguments and the system prompt

- [ ] **Write the failing tests** in `ClaudeCodeSubscriptionTests`:
  - `testClaudeCodeSearchArguments`: with `providerSearch`, `--tools
    WebSearch` replaces `--tools ""`, and `--allowedTools` lists
    `WebSearch` plus the MCP names; `--safe-mode`, `--strict-mcp-config`,
    `--disable-slash-commands`, the empty workspace and the stripped
    environment are unchanged; `WebFetch` appears nowhere.
  - `testClaudeCodeArgumentsWithoutSearchUnchanged`.
  - `testClaudeCodeSearchSystemPrompt`: the tools line gains "and
    WebSearch"; the spec §4 instruction follows. If CP0 found answers add
    their own "Sources:" list, the instruction asks for linked pages only,
    as CP0 recommends.
- [ ] **Run, implement, run.**

### Task 5.2: Parser events and the `init` check

**Interfaces:** `ClaudeCodeStreamParser.Event` gains
`.toolsListed([String])`, `.searchStarted` and
`.searchResults([WebSearchSource])` (spec §3).

- [ ] **Write the failing tests:**
  - `testParserSearchEventsFromFixture` (`claude-code-web-search.jsonl`).
  - `testParserSkipsMalformedSearchResults`: plain strings, entries without
    `content`, unsafe URLs.
  - `testInitWithoutWebSearchIsUnavailable`
    (`claude-code-init-without-websearch.jsonl`): the process stops and
    `.webSearchUnavailable(.claudeCode)` is thrown before any text.
  - `testClaudeCodeSourcesFromAnswerLinks`.
  - `testClaudeCodeRestartDeliversNothing`: on `ProviderSearchRestart`, no
    MCP response is written and the process ends as CP0 Q5 found.
- [ ] **Run, implement, run.**

### Task 5.3: The live check, and turning Claude Code on

- [ ] **Add** `testClaudeCodeSearchesLive`: the multi-search question
  through the Mac's Claude sign-in; a search, two sources, an answer.
- [ ] **Get the owner's approval,** run it, record it.
- [ ] **When it passes,** add `.claudeCode` to the set and update the test.

## Exit criteria

- The touched classes pass; `build` and `analyze` succeed; the full `test`
  once before the commit; CI passes.
- The live check passed, or `.claudeCode` stays off and the Hand-off says
  why.

## Reviewer checklist

- `WebFetch` can't be enabled by any path; mutation: add it, and a test
  fails.
- Every other argument F32 relies on is unchanged.
- The `init` check runs before any text reaches the reply.

## Hand-off

*Filled in by the CP5 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
