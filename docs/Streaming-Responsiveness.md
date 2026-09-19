# Streaming responsiveness

Chat history remains temporary. Streaming response text is published immediately,
while archive snapshots are coalesced for 500 ms and written on a serial utility
queue. The timer starts with the first unsaved fragment; later fragments do not
restart it. An archive snapshot is taken only when a write can start. Encoding,
archive normalization and atomic file replacement run on the background queue.

Appending the assistant message already sorts the active session and applies
retention. Individual fragments update its content and activity date without
repeating sorting and retention work.

## Save boundaries and ordering

New chats, accepted messages and workspace changes request an immediate background
save. Stop, successful completion, generation failure and app deactivation flush
pending changes without waiting for the streaming timer. A rejected draft does
not schedule a save. None of these UI actions waits for disk I/O.

There is at most one write in progress and one pending snapshot provider. Newer
requests replace the pending provider. If a write is already in progress, it
finishes before the newest pending state is captured and written. An older queued
snapshot therefore cannot overwrite a newer save or restore a cleared archive.
Cancelled timers check cancellation before touching the pending save.

This retains the existing `chats.json` format, atomic overwrite, five most recently
active sessions, and exclusion of temporary selection chats and session-only
message fields. There are no backups, recovery files, retries or save-warning UI.
Save failures are best effort and do not replace request feedback or affect Stop.
The app does not wait for writes on termination; abrupt exit or a failed save can
lose recent history. The initial archive load still runs synchronously at startup.

## Deterministic evidence

The offline tests use a controlled coalescing delay and, where needed, a gate in
front of a real archive write. They assert progress and write ordering rather than
machine-dependent latency thresholds:

| Check | Observed result |
| --- | --- |
| 1,000 save requests before the coalescing delay fires | One snapshot evaluation and one real archive write |
| 1,000 local stream fragments while the initial write is gated | All 1,000 incremental response lengths published; two writes total after Stop (initial and latest) |
| Stop with the initial write still gated | Request ownership released and producer cancellation completed before disk was released |
| Real `AppShellView`, 500 fragments and a gated write | Stop command handled; native composer accepted text and updated its draft before disk was released |
| Cloud completion and failure before the delay fires | Latest partial text saved without advancing the coalescing clock |
| Older active write, 100 superseded pending snapshots, then newer state or empty archive | Only the active and final snapshots written, in that order; late cancelled timer did not restore old state |
| New chats and a temporary stream during an outstanding save | Five ordinary sessions retained, evicted session stayed absent, temporary chat excluded |

The prior fragment path called the synchronous store once per fragment, plus
three times to create the initial session and its messages. That is 1,003 write
calls for the local test's 1,000-fragment scenario by source inspection, versus two
observed writes in the controlled test (about 99.8% fewer). This comparison is a
write-count result, not a measured CPU or latency speedup. Real streams can save
periodically as the 500 ms windows elapse.

The composer intentionally remains disabled while generating. The responsiveness
check preserves that policy and verifies typing after Stop through the native
editor and its real draft binding. It uses the shell's Stop command notification;
physical keyboard and mouse input were not manually timed.

## Verification and limits

Focused command:

```sh
scripts/verify-xcode.sh test \
  -only-testing:EnigmaTests/ChatSessionWriterTests \
  -only-testing:EnigmaTests/RequestLifecycleTests \
  -only-testing:EnigmaTests/ScreenViewTests/testRealComposerStopAndTypingRemainResponsiveWhileArchiveWriteIsBlocked
```

The focused run passed all 21 tests. A subsequent 44-test regression run covered
writer ordering, request lifecycle, local inference and File Mode fixture cleanup.
The final `scripts/verify-xcode.sh build`, `analyze` and `test` runs passed; the full
suite executed 543 tests with 10 opt-in tests skipped and no failures. Existing
archive assertions explicitly await the writer before reading disk, and File Mode
fixtures finish pending writes before removing their directories. Transcript and
privacy assertions are retained.

No real-provider throughput benchmark, Instruments main-thread/CPU trace,
large-history memory profile, frame-rate measurement or human input-latency
measurement was performed. The tests establish that archive work runs off the
main thread and cannot hold up token publication, Stop or subsequent native text
entry while the background write is blocked. Markdown rendering and other UI
work remain outside this change.
