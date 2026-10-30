# CP9: The map card

Read [agent-workflow.md](agent-workflow.md), the spec (§6.5, §6.6, §7,
"Failure handling"), `docs/design/UI-Style.md`, and the Hand-offs of
[CP6](cp6-places-and-weather.md#hand-off) and
[CP8](cp8-switch-over.md#hand-off).

## Goal

Every reply whose evidence included a places result shows a map card under
it, on any route and either kind of turn: a still Apple map with numbered
pins for the places the reply names, or for every place found when it names
none. Pins open Apple Maps. The card is never saved.

## Starting point

- **CP6:** a `.places` `WebSearchResult` carries `places: [MapPlace]`
  (identifier, name, coordinate, and distance near the user). The small-model
  path gets it from `OnDeviceSearchProvider`; the capable path from
  `PlaceSearchTool`, which already reports its sources through
  `onSources`.
- **`Enigma/Chat/ChatDomain.swift`:** `ChatMessage` with session-only fields
  (`activity`, `imagePreview`, `origin`) left out of `CodingKeys`.
- **The message list:** `EnigmaMessageList.swift` (`EnigmaReplyView`), in a
  lazy stack; `AssistantActivityView.swift` for the sources panel's look.
- **`TestHost.isActive`** to swap in placeholders.

## Tasks

### Task 9.1: Carrying the places onto the reply

**Files:** `ChatDomain.swift`, `LocalChatViewModel.swift`,
`PlacesAndWeatherTools.swift`. Tests in the new
`EnigmaTests/MapCardTests.swift`.

```swift
struct ChatMessage { /* … */ var mapPlaces: [MapPlace]? = nil }   // session-only
```

- [ ] **Write the failing tests:**
  - `testSmallModelPlacesReachTheReply`: a places route's result puts its
    places on the reply.
  - `testToolPlacesReachTheReply`: a `find_places` call on a capable turn
    does the same; two calls merge, in call order, without duplicates by
    identifier.
  - `testMapPlacesAreNeverSaved`: encoding and decoding a chat drops them;
    the saved JSON has no coordinate.
  - `testNoPlacesNoCard`: web and weather replies have `mapPlaces == nil`.
- [ ] **Run, implement, run.**

### Task 9.2: Choosing the pins

**Interfaces:**

```swift
struct MapPin: Equatable, Sendable { let number: Int; let place: MapPlace }
enum MapCard {
  /// Spec §6.6: places named in the reply, in first-mention order; all places when none match.
  static func pins(for places: [MapPlace], reply: String) -> [MapPin]
}
```

- [ ] **Write the failing tests:**
  - `testPinsFollowReplyOrder`: three places, the reply names the third
    first: it's pin 1.
  - `testPinsIgnoreCaseDiacriticsAndLeadingThe`: "café de flore" matches
    "Café de Flore"; "Bean Counter" matches "The Bean Counter".
  - `testPinsMatchFullNamesOnly`: "Blue Bottle" in the reply doesn't pin
    "Blue Door"; "Joe's Pizza" doesn't pin "Joe's Pizza Broadway" unless the
    full name appears.
  - `testNoMatchPinsEveryPlace`: in result order.
  - `testOnlyNamedPlacesArePinned`: two of ten named, two pins.
- [ ] **Run, implement, run.** Matching is plain normalized substring search
  on whole words, deterministic and local; no model is asked.

### Task 9.3: The card

**Files:** create `Enigma/Chat/MapCard.swift` (app target); modify
`EnigmaMessageList.swift`.

- [ ] **Write the failing tests:**
  - `testCardAppearsOnlyAfterTheReplyFinishes`: no card while streaming;
    the card once `finishGeneration` runs.
  - `testPlaceholderInTestHost`: the test host shows the placeholder with the
    card's size and labels, and no `Map`.
  - `testCardAccessibility`: the card's label is "Map of ‹count› places";
    each pin is a button "‹n›, ‹name›", plus "‹d› away" near the user.
  - `testOpenInMapsOpensAllPins` and `testPinOpensItsPlace`, through an
    injected opener (no Apple Maps launch in tests).
- [ ] **Implement** spec §6.6: a SwiftUI `Map` with `.standard` style,
  `interactionModes: []`, about 190 pt tall, markers numbered by
  `MapCard.pins`, the camera fitting the pins, Apple's logo and legal link
  uncovered, an **Open in Maps** button, corners and hairline matching the
  sources panel, built only when its row appears in the lazy stack.
- [ ] **Run;** then build the signed app from Xcode (a stable Apple
  Development identity, as `AGENTS.md` says) and ask the owner to check
  the card on a small and a capable model: "cafes near me", "ramen in
  Soho", `/maps bookshops`, and a chat reopened from Recents (no card).
  Record what the owner saw.

### Task 9.4: Screenshot

- [ ] **Add** a map card screenshot beside the other reply screenshots
  (paper and dark), taken from the signed app with invented places in a
  public area, and list it for CP10's docs.

## Exit criteria

- `MapCardTests`, `PlacesAndWeatherToolTests`, `WebSearchTests` and the
  message-list window tests pass; `build` and `analyze` succeed; the full
  `test` once before the commit; CI passes.
- The owner checked the card in the signed app.

## Reviewer checklist

- No path saves `mapPlaces` or a coordinate; mutation: add it to
  `CodingKeys`, and a test fails.
- The map never takes scrolling; no tiles load in the test host.
- Pin numbers match the reply's first mentions; unmatched replies pin all.
- Apple's attribution stays visible at every card width.

## Hand-off

*Filled in by the CP9 worker, 2026-10-30. Decisions D145–D162 in
[overnight-decisions.md](overnight-decisions.md).*

1. **Summary:** Tasks 9.1–9.3 are built, test-first; Task 9.3's signed-app check and
   Task 9.4's screenshot are the owner's. Every search route (small-model `submit`, the
   screen path, cloud with search, and `find_places` on capable turns) collects places in
   `LocalChatViewModel.replyPlaces`, merged in order without duplicates, only for the running
   request and only when the places source reached the model; `finishGeneration`, or
   `stopStreaming` on Stop, moves them onto the session-only `ChatMessage.mapPlaces` when the
   reply ends, and a restart or a new request clears them (D146, D153, D156).
   `MapCard.pins(for:reply:)` picks the pins (D147). `EnigmaReplyView` shows `MapCardView`
   under a finished reply: a 190 pt `.standard` `Map`, `interactionModes: []`, numbered pins
   that open the place in Apple Maps, **Open in Maps** for all pins, 6 pt corners and a hairline
   (D148). The live map exists only while the card is on screen, since the message list isn't
   lazy (D145); scroll-wheel events pass through to the chat (D149). The test host gets a
   placeholder with the same size and pin controls, and no `MKMapView`.
2. **Files:**
   - New: `Enigma/Chat/MapCard.swift` (`MapPin`, `MapCard`, `MapCardOpener`, `MapCardActions`,
     `MapCardOpening`, `MapCardView`, `MapScrollPassThrough`), `EnigmaTests/MapCardTests.swift`; both registered
     in the Xcode project.
   - `Enigma/Chat/ChatDomain.swift` (`mapPlaces`, not in `CodingKeys`),
     `Enigma/Chat/EnigmaConversationLogic.swift` (`Reply.mapPins`),
     `Enigma/Chat/EnigmaMessageList.swift` (the card under the reply),
     `Enigma/LocalInference/LocalChatViewModel.swift` (`addReplyPlaces`, `attachReplyPlaces`,
     `replyPlaces` private; request-scoped, attached on Stop, cleared on restart and at each
     request's start).
   - `EnigmaTests/NativeToolRequestTests.swift`: `testRestartDropsTheFirstRunsPlaces`.
   - `PlacesAndWeatherTools.swift` needed no change: its `onPlaces` already reports each call's
     places; the merge is in the view model.
3. **Decisions:** D145 (on-screen live map instead of a lazy stack), D146 (when places reach the
   reply; every ending with text), D147 (matching details; "Map of 1 place"), D148 (look),
   D149 (scroll pass-through), D150 (opening Maps), D151 (how the view tests check the card),
   D152 (steps left to the owner and orchestrator); round 1: D153–D155 (orchestrator's),
   D156 (no stale places; only places the model saw), D157 (camera, matching, opening, off-screen
   placeholder), D158 (route test fakes); round 2: D159–D160 (orchestrator's), D161 (the lookup's
   time limit resumes the wait itself), D162 (a late request's places; the screen fallback
   replaces).
   Beyond the brief: `testReplyRowShowsTheCardOnceFinished` (the reply row, in progress, finished
   and reopened) and `testScrollingPassesThroughTheMap`.
4. **Verification** (`scripts/verify-xcode.sh`, logs in `/private/tmp/claude-501/f29-cp9/`):
   - RED: `MapCardTests` failed to compile (no `MapPin`, `MapCard`, `mapPlaces`, `mapPins`).
   - `MapCardTests`: 16 executed, 0 failed.
   - `MapCardTests`, `PlacesAndWeatherToolTests`, `WebSearchTests`, `NativeToolRequestTests`,
     `OnDeviceSearchTests`, `ChatPersistenceTests`: 249 executed, 0 failed.
   - `build` succeeded; `analyze` succeeded, no warnings in the changed files.
   - Review round 1 (no Blocker; S1–S3 and N1–N9 fixed): new tests
     `testScreenPathPlacesReachTheReply`, `testCloudSearchPlacesReachTheReply`,
     `testWhitespaceReplyGetsNoCard`, `testPlacesTheModelNeverSawGetNoCard`,
     `testStopAttachesAndLeavesNothingStale`, `testToolPlacesAfterStopAreDropped`,
     `testPinsTreatAmpersandAsAndAndSkipEmptyNames`, `testCameraFitsFarApartPins`,
     `testOpeningIgnoresClicksWhileRunning`, and `NativeToolRequestTests.testRestartDropsTheFirstRunsPlaces`.
     Mutants (no attach on Stop, no clearing on restart) fail `testStopAttachesAndLeavesNothingStale`
     and `testRestartDropsTheFirstRunsPlaces`; restored. After the fixes: `MapCardTests` 25,
     and the six classes together 259 executed, 0 failed; `build` and `analyze` succeeded.
   - Review round 2 (no Blocker; S1, S2, N1 fixed): new `testLookUpGivesUpWhenMapKitNeverAnswers`
     and `testPlacesForAnEndedRequestAreDropped`. Mutants (the timer only cancels; no request
     check in `addReplyPlaces`) each fail their test; restored. After the fixes: `MapCardTests` 27,
     and the six classes together 261 executed, 0 failed; `build` and `analyze` succeeded.
   - Not run: hosted UI classes (none changed; `EnigmaConversationTests`,
     `EnigmaMainWindowTests` and `EnigmaCompactPanelTests` draw replies and run in the full
     suite), the full suite, a review round, the `CodingKeys` mutation (D152).
5. **Limitations:**
   - The live `Map`, its pins' clicks, the scroll pass-through and Apple's attribution at narrow
     widths were never seen running: the test host draws only the placeholder. That's the
     owner's check below.
   - VoiceOver labels are tested through the functions that make them and the markers named by
     them, not by reading the accessibility tree (D151).
   - A card appears after Stop and after an error when the reply has text (D146, D153); places a
     `find_places` call returns after Stop are dropped.
   - Accepted (D160): Codex's restart can race the first run's late `find_places` result; places
     named past a truncated places excerpt can still get pins.
   - The screen path's fallback replacing places (D162) has no test.
   - Matching needs spaces between words: Japanese, Chinese and other scripts without spaces
     rarely match, so those replies pin every place.
   - The view tests can't click in their offscreen window, so the "ignore clicks while opening"
     rule is tested on `MapCardActions`, not on the buttons.
   - Opening Maps asks Apple for the place by its identifier (D150); the place query already went
     to Apple Maps.
6. **For the next checkpoint:**
   - **Owner, Task 9.3:** build the signed app from Xcode (stable Apple Development identity) and
     check on a small and a capable model: "cafes near me", "ramen in Soho", `/maps bookshops`,
     and a chat reopened from Recents after relaunching the app (no card; D154). Also check: the wheel scrolls the chat over the
     map; pins and Open in Maps open Apple Maps; Apple's logo and Legal link show in the compact
     panel's width; pins show numbers without name titles (D154); Paper and Ink; two
     far-apart places (for example "Apple Park and the Sydney Opera House") frame both.
   - **Owner, Task 9.4:** a map card screenshot beside the other reply screenshots (Paper and
     Ink), from the signed app with invented places in a public area, for CP10's docs.
   - CP10: `docs/Web-Search.md` should say the card isn't saved and a reopened chat has none.
