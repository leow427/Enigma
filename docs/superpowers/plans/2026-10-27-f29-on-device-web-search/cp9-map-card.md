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

*Filled in by the CP9 worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
