# Chat scrolling and appearance

Implemented on 2026-09-06, based on `e12305a` (`feat/file-mode`).

## Scrolling

The old layout observer unconditionally scrolled to the bottom after every lazy
stack size change. Scrolling into older rows causes fresh measurements, so the
observer could undo the reader's scroll about 30 milliseconds later.

The native observer now retains whether the reader is following the latest
message. Trackpad/scroller tracking suspends following before movement begins;
ordinary offset changes also detect wheel and keyboard navigation. Leaving the
bottom cancels queued corrections, and each correction rechecks the current
intent before executing. Returning within two points of the bottom restores
following. Document geometry observations distinguish growth/resizing from
navigation and keep the resume behavior current. Observers and queued work are
removed when the view leaves its window. Session identity and lazy rendering
remain unchanged.

## Appearance

The botanical accents first added here were replaced by the Paper and Ink design
(see [UI-Style.md](../UI-Style.md)). The chat sits on the opaque `background`,
the composer's edge picks up the `accent` while it has focus, the open chat in
the sidebar has a small dot, and replies carry the character or its mark. Reduce
Motion turns springs into cross-fades.

## Verification

- `scripts/verify-xcode.sh build`: passed.
- `scripts/verify-xcode.sh test`: 340 tests, seven existing opt-in runtime skips,
  zero failures.
- `scripts/verify-xcode.sh analyze`: passed.
- Focused `ScreenViewTests`: 13 passed.
- Native flipped/unflipped scroll fixtures cover a tiny movement racing queued
  layout work, content growth while reading, returning to the bottom, and live
  scrolling. The real 40-message SwiftUI panel regression checks an eight-point
  scroll during streaming and access to the oldest messages.
- The development-signed app was built and run from Xcode. Its accessibility
  hierarchy was inspected. The privacy-excluded panel does not appear in computer
  screenshots, so this is not claimed as a successful manual visual scroll test.

The image below is a native test rendering of the chat with synthetic content.
Physical trackpad feel still benefits from user review. GitHub CI is reported in
the pull request.

![A chat in the current design](design/ui-revamp/screenshots/phase-10/chat-paper.png)
