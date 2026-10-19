# CI test reliability — 2026-10-19

Hosted UI tests failed now and then on GitHub's macOS runners while passing
locally. This round measured how often each test failed on the runners, found
the cause of each failure, and fixed it, without weakening assertions or
retrying tests.

## How it was measured

The **Stress tests** workflow (`.github/workflows/stress.yml`, described in
[Testing.md](../Testing.md)) runs the suite repeatedly on five `macos-26`
runners and counts failures per test, with no retries. A full-suite stress run
is 30 suite runs. Focused runs repeated only the main-window, Settings,
conversation, and compact-panel classes, which fail more often in isolation.

| Commit | What it measures | Runs with a failure |
| --- | --- | ---: |
| 3f44fad (baseline) | full suite | 11 of 30 |
| 67aa6c9 (streaming and menu-wait fixes) | full suite, two runs | 4 of 60 |
| 0bdebf6 (menu focus return, Settings panel) | full suite | 2 of 30 |
| 0bdebf6 | main window + Settings classes | 7 of 100 |
| 5218190 (menu opening, Replace text) | full suite | 0 of 30 |
| 5ee0749 (character frames) | main window, Settings, conversation, compact panel classes | 0 of 60 |
| 5ee0749 | full suite | 0 of 30 |

## Failures and their causes

**Streaming while the archive write is blocked** (11 of 30 baseline runs).
`ScreenViewTests/testRealComposerStopAndTypingRemainResponsiveWhileArchiveWriteIsBlocked`
waited 5 seconds for 500 streamed fragments. Each fragment re-evaluates the
whole `AppShellView`, about 3 ms in the Debug test host on an M-series Mac and
roughly three times that on a runner. What the test checks, that streaming
never waits for the disk, doesn't depend on speed: the first archive write is
blocked until the test releases it, so a regression never finishes. The wait is
now 60 seconds, and the test also asserts the write was still blocked when the
burst finished.

**Long replies got slower to stream** (found while profiling the above).
`ChatMarkdownView` parsed the whole reply on every update. At 16,500 characters
that was two thirds of the main thread and 27 ms per fragment. `ChatMarkdownStream`
now parses only the part after the last settled block, with output identical
to a whole-reply parse (a property test checks every prefix of edge-case and
generated documents). The same reply now costs about 8 ms per fragment.

**Menus and keyboard focus** (several tests, 2–12% of focused runs).
- The Settings menu test slept 150 ms before typing, assuming the menu had
  focus by then. It now waits for the menu to take focus.
- When a menu closed, its trigger handed focus back one `Task.yield` later, a
  guess at when the closing list had let go; on a slow runner the list took
  focus back and the composer stayed unfocused after Escape (12 of 100 focused
  runs). Focus now returns once the list's `onDisappear` runs.
- When a menu opened, the click focused the trigger after the list had asked
  for focus, and sometimes won (6 of 100). The trigger now hands focus back to
  its open list.
- Mid-run, something on the runner occasionally activated another app, so the
  Settings tests' plain window couldn't be key. They now use a non-activating
  panel, as the main-window tests do.

**A 24-minute hang** (once in CI history, once in 60 stress runs). A spindump
showed `clickTestControl`'s synthetic click on Replace text landing on a
focused text view drawn over it, whose mouse-down then waited forever for a
mouse-up. A per-test time allowance now fails such a test after 2 minutes with
a spindump instead of freezing the job. The edit-revision tests wait until
Replace text is uncovered before clicking. A broader change to the click
helper was tried and reverted: it passed locally but failed every stress run.

**The character's fall** (1 of 100 focused runs). The test sampled positions
from a polling loop, so a delayed loop could miss the whole fall. The
controller can now record every frame it computes, and the test reads those.

**Replace text tested only one case.** The shell read the shared selection
service, which tests can't give a target, so only the "can't replace" branch
ran. The service is now an input with the shared one as the default, and both
edit-revision tests cover both cases.

## Limits

- A finite number of runs can't prove a failure rate of zero; the table
  records what was observed.
- The whole shell still re-renders for each streamed fragment, a constant cost
  of a few milliseconds per update in the Debug build. Only the part that grew
  with the reply's length was removed.
- Local UI runs share the screen and keyboard focus with anything else running
  hosted tests at the same time, including another checkout.
