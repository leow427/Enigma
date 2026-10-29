# F30 cloud search fixtures

Recordings from the F30 CP0 probes (2026-10-29), for the provider-search parsers
(CP2–CP5). Read through `#filePath` by `CloudSearchFixture` (CP1).

Every file is scrubbed: Codex thread and turn IDs are `thread-one` and
`turn-one`, item and call IDs `item-N`; Claude Code session IDs are
`session-one`, and `uuid`, message, request and tool IDs are numbered
placeholders (`uuid-N`, `msg-N`, `request-N`, `toolu-N`, `srvtoolu-N`);
signatures are `REDACTED`; times are `0`; local paths are under `/tmp/probe`;
account details are placeholders. Codex files keep only the server's
notifications and requests, without account, rate-limit, warning and
moderation messages. Page titles, URLs and snippets are public search results.

**OpenAI and Anthropic are synthetic.** The owner has no API key for either,
so these files are written from the providers' documented shapes (fetched
2026-10-29), with placeholder IDs (`response-0`, `ws-0`, `message-0`, `fc-0`,
`call-0`, `msg-0`, `srvtoolu-0`, `toolu-0`), `REDACTED` encrypted fields and
zero usage. Where the docs are silent they follow the nearest documented
shape; the Hand-off in `cp0-spike.md` (Q1, Q2) lists each assumption. Replace
them with recordings once someone with a key runs the probes.

| File | Source | Date | Question | Scrubbed | Kind |
| --- | --- | --- | --- | --- | --- |
| `codex-web-search.jsonl` | Codex app server 0.164.0, gpt-5.6-luna, `config.web_search: "live"` with dynamic tools | 2026-10-29 | "Compare the current prices of the cheapest MacBook Air and the cheapest MacBook Pro in the US. Link your sources." | IDs, times, paths; account and warning messages dropped | Recorded |
| `codex-search-and-dynamic-tool.jsonl` | As above, with a `get_saved_note` dynamic tool answered with a fixed note | 2026-10-29 | "Look up my saved note about the conference with get_saved_note, then search the web for that conference's dates this year. Link your source." | As above | Recorded |
| `claude-code-web-search.jsonl` | Claude Code 2.1.312, `haiku` (claude-haiku-5-5), F32 tool arguments with `--tools WebSearch` | 2026-10-29 | The MacBook question above | Session, uuid, message, request and tool IDs; signatures; timestamps; paths; plugins; the `initialize` reply's account, models and agents | Recorded |
| `claude-code-init-without-websearch.jsonl` | The first lines of `claude-code-web-search.jsonl`, up to `init`, with `WebSearch` removed from `init.tools` | 2026-10-29 | None (start-up only) | As above | Derived |
| `openai-search-and-function.sse` | OpenAI Responses docs: generic `response.output_item.added/done` events with a `web_search_call` item, a `message` with a `url_citation`, then a `propose_edit` function call | 2026-10-29 | "<selection> Fix this sentence so it's accurate today." | Placeholder IDs | Synthetic. Assumes the cited link is in the text as Markdown at the annotation range; no `response.web_search_call.*` events (their names aren't documented) |
| `openai-multi-search.sse` | As above: a `search` call with `queries` and `sources`, an `open_page` call, an answer with two citations | 2026-10-29 | The MacBook question | Placeholder IDs | Synthetic |
| `openai-replay-request.json` | The second step after `openai-search-and-function.sse`, with the function result. The `web_search_call` item keeps `id` and `status`, which the Responses input schema requires; other items are replayed as F32 does (no `id`/`status`) | 2026-10-29 | As above | Placeholder IDs | Synthetic. Models the second of CP0's three replay candidates (Q1); which one the API accepts is unverified |
| `anthropic-search-and-tool.sse` | Anthropic streaming and web search docs: text, `server_tool_use` + `web_search_tool_result`, cited text (`citations_delta` with `web_search_result_location`), then a `propose_edit` `tool_use`; `stop_reason: tool_use` | 2026-10-29 | The selection question | Placeholder IDs, `REDACTED` encrypted fields | Synthetic. Direct calls only: no code-execution blocks, as with `allowed_callers: ["direct"]`. The spec's configuration (default callers, `response_inclusion: "excluded"`) runs searches inside code execution; that stream isn't fixtured and is to be recorded in CP3's live check |
| `anthropic-step-replay-request.json` | The next step: every assistant block unchanged, then only `tool_result` blocks, same tools (with `allowed_callers: ["direct"]`, matching the stream) | 2026-10-29 | As above | As above | Synthetic, following the docs' "send back exactly as received" rule |
| `anthropic-pause-turn.sse`, `anthropic-pause-continuation.sse` | A turn that stops with `pause_turn` after one search, and the continuation that answers | 2026-10-29 | The MacBook question | As above | Synthetic |
