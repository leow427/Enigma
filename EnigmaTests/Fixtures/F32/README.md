# F32 stream fixtures

Streams for the F32 tool-loop parsers (CP2, CP3), from the CP0 probes in
`NativeToolsProbeTests`. Every file is scrubbed: IDs are replaced with
placeholders (`msg-0`, `toolu-0`, `response-0`, `fc-0`, `call-0`,
`chatcmpl-0`), times with `0`, and local paths with `/tmp/probe/…`.

Cases: `text` (no call), `call`, `text-then-call`, `forced` (tool choice
forced by name), and `cut-mid-call` (a call stream truncated inside the
arguments). Anthropic and `llama` add `thinking-call`.

| Folder | Source |
| --- | --- |
| `llama/` | Recorded from `llama-server` b11734 with Gemma 4 12B Q5_K_M, using today's server arguments and today's request keys (`LocalMultimodalClient`: response-style system prompt, `cache_prompt: false`, thinking off). `thinking-call` turns thinking on (`enable_thinking: true`, `reasoning_budget: 1024`), so `reasoning_content` deltas come first. `forced` used `tool_choice: "required"` |
| `llama/qwen38/` | Recorded the same way with Qwen3.8 27B IQ3_XXS. Its `forced` stream never calls the tool (it writes text until `max_tokens`): `required` isn't enforced for this family |
| `anthropic/` `text`, `call`, `text-then-call` | Recorded through Claude Code (`--include-partial-messages`), which streams the Messages API's own events. The tool is Claude Code's `Read`; its input was rewritten to a placeholder path in the same number of deltas, keeping the recorded empty first `input_json_delta`. A `ping` event was added after the first block start, as the API sends one and Claude Code drops it |
| `anthropic/` `forced`, `cut-mid-call` | `forced` is the recorded `call` stream (a forced call opens with the `tool_use` block); `cut-mid-call` truncates it |
| `anthropic/thinking-call` | **From docs, not recorded:** written from Anthropic's streaming documentation (thinking block, `thinking_delta`, `signature_delta` before `content_block_stop`, then a `tool_use` block); its `message_start` is the recorded one from `call` |
| `openai/` | **From docs, not recorded:** written from OpenAI's Responses streaming and function-calling documentation; no API key was available. `forced` is identical to `call` (a forced call streams like any call) |
| `gemini/` | **From docs, not recorded:** written from the Gemini API reference and today's `GeminiContentClient`; no API key was available. Function calls arrive whole, with a `thoughtSignature` on the call part; events are CRLF-separated. `forced` is identical to `call`. `cut-mid-call` is a text chunk followed by the `call` chunk truncated inside its arguments |

Streams from docs haven't been checked against a live recording: CP5 switched
the feature on without API keys, so the OpenAI, Anthropic and Gemini API tool
streams are known only from these fixtures (the same model families were
evaluated through Codex and Claude Code). `NativeToolsProbeTests` records them
when a key is available.

`eval.jsonl` is CP5's tool-use eval: 60 invented prompts, each with the tool a
capable model should call first (or `none`), read by `NativeToolsEvalTests`.
