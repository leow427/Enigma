# CP1b: Routing fixes — CP1's second review

Read [agent-workflow.md](agent-workflow.md), the spec (§6.1 in full, §1),
and the Hand-offs of [CP0](cp0-spike.md#hand-off),
[CP0b](cp0b-second-probe.md#hand-off) and
[CP1](cp1-foundations.md#hand-off).

## Goal

Small models keep CP1's rule routing (`SearchRouting.decide`) under F32.
CP1's second review (2026-10-28) found that it misroutes common questions.
Fix them exactly as spec §6.1 now says, pin the two rules no test caught,
and check the F32 and F30 names this plan relies on. Capable models never
call `SearchRouting.decide`, so nothing changes for them. Brave still serves
every search, so users see nothing new yet.

This checkpoint also opens the branch's draft pull request and turns
Auto-fix on, so CI runs on every later push.

## Starting point

- **CP0b merged `main`** into the branch: F32 and F30 are in.
- **`Enigma/Search/SearchRouting.swift`:** `decide(question:)` returns a
  `SearchDecision` with `route`, `needsCurrentLocation` and `namedPlace`;
  `webQuery(_:city:)`.
- **`Enigma/Search/LocationService.swift`:** `LocationIntent` with
  `needsLocation`, `hasNearbyCue`, `asksAboutWeatherNow`, `weatherPlace`,
  `matches`, `namedPlace`, the private `weatherTopic`, `asksAboutNow`,
  `nearbyCue` (`local (weather|restaurants?|cafes?|events|places)`),
  `weatherPlacePattern` and `timePhrase`.
- **`EnigmaTests/SearchRoutingTests.swift`:** `testRoutes` (a table),
  `testWeatherHasExactlyOneWayToFindItsPlace`, and the `webQuery` tests.
- **`LocalChatViewModel.search`** builds the request's `recency` from the
  typed question (`WebSearchPolicy.recency`), not `contextualQuery`.

## The findings (CP1 review round 2, 2026-10-28)

| # | Where | What's wrong | Examples |
| --- | --- | --- | --- |
| 1 | `LocationIntent.asksAboutWeatherNow` | Any weather topic word plus "what's/what is/what are/is it" routes to weather; "raining" and "snowing" aren't topic words | "what are the best rain jackets", "what is the temperature to bake salmon" (current location), "what is the safe temperature for chicken" (place "chicken"); "is it raining near me" goes to places |
| 2 | `nearbyCue`, `SearchRouting.webQuery` | "local <place word>" only works for restaurants, cafes, events and places, and `webQuery` deletes "local" anyway | "local gyms", "local bars", "best local pizza" go to web without location, and the query loses "local" |
| 3 | `weatherPlace`, `timePhrase` | Only the first in/at/for/near candidate is tried; noon, midnight, lunch, sunrise, christmas count as places; home and work too | "is it going to rain at noon" (place "noon"), "will it rain in the afternoon in london" (London lost), "what's the weather at home today" |
| 4 | `SearchRouting.swift`, `namedPlace: needsLocation ? nil : place` | Untested: the mutant `namedPlace: place` survives | "weather near me for the marathon", "forecast nearby for hiking" |
| 5 | `LocalChatViewModel.search`, recency | Untested: using `contextualQuery` survives | A written query carrying "latest" |
| 6 | The named-area places rule | Developer and other questions route to places | "progress bars in swiftui", "best json library in python", "bar exam in california", "atm in spanish" |

The reviewer's notes and logs are summarized here; the spec's §6.1 table is
the rule to build.

## Tasks

### Task 1b.1: Names

- [ ] **Check** the plan's Global Constraints "F32 and F30 names" against
  the merged code with `grep -rn`, and record each in the Hand-off.

### Task 1b.2: Weather (findings 1 and 3)

**Files:** `Enigma/Search/LocationService.swift`; tests in
`SearchRoutingTests`.

- [ ] **Write the failing rows** in `testRoutes` (route, needs location,
  named place):
  - web, no location, nil: "what are the best rain jackets", "what's the
    best snow blower", "what are snow tires", "is it worth buying a rain
    gauge", "what is the normal body temperature", "what is the temperature
    to bake salmon", "what is the boiling temperature of water", "what is
    the temperature of the sun", "what is the safe temperature for
    chicken", "what's the internal temperature for medium rare steak";
  - weather, location, nil: "is it raining near me", "will it rain today",
    "do i need an umbrella today", "what's the temperature outside";
  - weather, no location, "denver": "is it snowing in denver today";
  - weather, no location, "london": "will it rain in the afternoon in
    london";
  - weather, no location, "rome": "what's the weather in the evening in
    rome";
  - weather, location, nil (a time or home/work is never the place, so the
    current location is used, as for "weather today"): "is it going to rain
    at noon", "what's the weather at midnight", "will it rain at lunch",
    "weather at sunrise tomorrow", "what's the weather for christmas",
    "what's the weather at home today", "will it rain at work today". If
    CP1's code gives any of these no location today, record what it gives
    and follow spec §6.1's rule that weather needs somewhere to look up.
- [ ] **Run** `scripts/verify-xcode.sh test -only-testing:EnigmaTests/SearchRoutingTests`;
  expect the new rows to fail.
- [ ] **Implement** spec §6.1: "weather"/"forecast" keep the "now" words;
  bare topic words (temperature, rain, raining, snow, snowing, umbrella)
  need a time word, a weather verb or "do i need"; `weatherPlace` loops over
  every match and skips times and home/work/school; `timePhrase` gains the
  listed words and holidays.
- [ ] **Run;** every row passes, old and new.

### Task 1b.3: "local" and named areas (findings 2 and 6)

**Files:** `LocationService.swift`, `SearchRouting.swift`; tests in
`SearchRoutingTests`.

- [ ] **Write the failing rows:**
  - places, location: "local gyms", "local bars", "local hotels", "local
    pharmacy", "local parks", "local libraries", "local coffee shops",
    "best local pizza", "bars near me";
  - web, no location: "progress bars in swiftui", "add error bars in
    matplotlib", "best json library in python", "what is the best logging
    library in python", "bar exam in california", "atm in spanish";
  - places, no location: "best pizza in brooklyn", "ramen in soho" (still);
  - `webQuery`: "local gyms" with city "Chicago" gives "gyms near Chicago";
    without a city it stays "local gyms".
- [ ] **Run;** expect failures. **Implement** spec §6.1: "local" plus any
  place word is a nearby cue (this changes `needsLocation` for those
  questions, which the owner approved with the spec on 2026-10-29); the
  ambiguous words skip the named-area rule; `webQuery` keeps "local <word>"
  without a city. **Run** again.
- [ ] **Check the wider effect:** run `ComposerIntentTests`,
  `ComposerIntentPhrasingTests`, `WebSearchTests` and `MessagesTests`, since
  `LocationIntent` feeds automatic search. A phrasing-corpus row that now
  differs is reported to the owner, not changed.

### Task 1b.4: The two untested rules (findings 4 and 5)

- [ ] **Add** "weather near me for the marathon" and "forecast nearby for
  hiking" to `testWeatherHasExactlyOneWayToFindItsPlace`, and a
  `testRoutes` row expecting weather, location, nil.
- [ ] **Change** `WebSearchTests.testWrittenQueryCannotChooseRoute` so the
  written query carries a recency word (`SearchCloudProvider(output:
  "latest cafes near me")`) and assert `request.recency == nil`. This adds an
  assertion; nothing is weakened.
- [ ] **Mutation-check both** in a scratch copy: `namedPlace: place`, and
  recency from `contextualQuery`; each must now fail a test.

### Task 1b.5: The pull request

- [ ] **After the commit is pushed,** open the draft pull request (`gh pr
  create --draft`, "On-device web search (F29)", the plan's Goal and a
  checkpoint checklist, no attribution lines) and turn on Auto-fix. Check
  CI passes.

## Exit criteria

- `SearchRoutingTests`, `WebSearchTests`, `ComposerIntentTests`,
  `ComposerIntentPhrasingTests` and `MessagesTests` pass; `build` and
  `analyze` succeed; the full `test` once before the commit.
- Both mutants are killed.
- The draft pull request exists with Auto-fix on, and CI passes.

## Reviewer checklist

- Every example in the findings table has a row with spec §6.1's expected
  route, location and place.
- Nothing changed for capable models: `submitNative` doesn't call
  `SearchRouting`.
- The `needsLocation` change is limited to "local <place word>".
- No test was weakened; the phrasing corpus is unchanged or its differences
  went to the owner.

## Hand-off

*Filled in by the CP1b worker.*

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
