# Test reliability — 2026-09-19

This follow-up addresses the intermittent screenshot, streaming, welcome, and
window-focus checks recorded during the audit work, plus the request-cancellation
and process-timeout fixtures reviewed with them. It preserves the assertions
about temporary chats, screenshot consent, removed images, and file recovery.

## Changes

- **Screenshot controls:** hosted tests install invisible, noninteractive native
  markers behind Retake, Remove, and the consent buttons. A single native mouse
  click uses the actual control bounds. OCR still verifies the displayed scope,
  provider, permission explanation, and attachment state. Tests never call the
  button's action directly or retry a failed action. Normal app views supply no
  markers; no accessibility permission or private accessibility API is needed.
- **UI readiness:** bounded waits check the editor, keyboard focus, hit testing,
  and panel frame instead of sleeping a fixed number of milliseconds. A failed
  prerequisite stops the case at its call site. Selection expansion still runs
  the real animation and checks its final frame; it does not use `minSize` as a
  completion signal because SwiftUI can subsequently update that constraint.
- **Welcome and cleanup:** each welcome test owns its composer and verifies a
  different draft after each exit. Hosted screenshot/selection fixtures stop
  their streams and drain background saves before removing their temporary data.
- **Streaming with a blocked archive:** wait for producer startup and the first
  rendered response before releasing the remaining burst. All 500 individual
  updates must publish, Stop must cancel the producer before the disk gate opens,
  typing must update the real editor binding, and the final archive must contain
  all 500 characters. The separate 1,000-fragment lifecycle test remains intact.
- **Cancellation:** token waits match the expected text in the request's session.
  An unrelated activity/status publication cannot satisfy them.
- **Process failures:** separate EOF and timeout cases initialize a real fake
  process over pipes. The timeout case confirms receipt of the unanswered request
  before advancing an injected deadline. Initialization failure cannot count as
  the expected request timeout. Production still sleeps for the same 60-second
  deadline; EOF must produce a disconnection error.

## Repeating checks

Use the repository's verification helper. To repeat an affected suite across
fresh test-host launches, without retrying away failures:

```sh
scripts/verify-xcode.sh test -only-testing:EnigmaTests/ScreenViewTests \
  -test-iterations 10 -test-repetition-relaunch-enabled YES
```

The measured focused set covers screenshot Retake/Remove, three consent cases,
blocked-archive streaming, repeated screen submissions, the three welcome exits,
selection expansion, two Settings focus cases, capture cancellation, direct API
replacement/cancellation, and the separate process EOF/timeout cases.

## Verification evidence

- `scripts/verify-xcode.sh build`, `test`, and `analyze` passed. The full suite
  executed **544 tests, with 10 existing opt-in skips and zero failures**.
- The final focused set passed **140 executions: 14 cases across 10 fresh
  test-host launches**, with no failures or retries.
- Four temporary fault-injection checks each failed as intended: disconnecting
  Remove's action, dropping stream text after character 250, returning the wrong
  timeout error, and leaving the welcome composer disabled. All mutations were
  restored before final verification.
- The unchanged baseline's ten selected cases passed all three launches. The
  following medians describe local execution time, not a measured failure rate:

| Case | Baseline, 3 launches | Updated, 10 launches |
| --- | ---: | ---: |
| Screenshot Retake/Remove and request exclusion | 15.140 s | 3.874 s |
| Stop and typing during a blocked archive write | 1.988 s | 0.935 s |
| All three welcome exits | 1.354 s | 0.773 s |
| Selection composer and animated expansion | 2.416 s | 1.827 s |

## Limits

These are offline fixtures and hosted UI checks. They do not establish live
provider/model quality, interactive Screen Recording or accessibility consent,
or real multi-display capture behavior. The existing opt-in runtime and model
checks retain their prerequisites. Interactive permission checks must use the
stable signed app described in [AGENTS.md](../AGENTS.md).

A finite run cannot establish that the entire suite is free of intermittent
failures. The unchanged baseline passed the ten selected cases across three
fresh launches despite the previously recorded failures; reliability claims
must therefore distinguish repeat-run evidence, reduced work, and stronger
failure detection from a measured long-term failure rate.
