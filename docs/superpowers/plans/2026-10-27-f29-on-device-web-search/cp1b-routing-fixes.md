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

1. **Summary:** Small-model routing now follows spec §6.1 as CP1b amended
   it. A bare weather topic word (temperature, rain, raining, snow, snowing,
   umbrella) counts only with a time word, a weather verb or "do i need";
   "weather"/"forecast" keep CP1's now words. The weather place tries every
   in/at/for/near candidate, skips times and home/work/school, and stops
   before a trailing time. "local" plus any place word is a nearby cue, and
   `webQuery` keeps "local <word>" without a city. The ambiguous place words
   (bar(s), park(s), atm(s), library/libraries) skip the named-area rule. The
   two untested rules (findings 4 and 5) are pinned, and both mutants die.
   Capable models are unchanged: `submitNative` never calls `SearchRouting`.
   After review round 1 the following also hold:
   - "local" with an ambiguous word in a how-to or developer question isn't
     a nearby cue.
   - "local <ambiguous word> in <area>" is a named area.
   - Languages are never areas or weather places.
   - Easter, christmas, sunrise, sunset and dinner are times only when they
     stand alone ("easter island" is a place).
   - Parts of the day use the current location.
   - "temperature in <named place>" is weather.
   - Weather candidates end at the next preposition, so long drafts stay
     linear.
2. **Files:**
   - `Enigma/Search/LocationService.swift`: `LocationIntent`'s weather rule
     (`asksAboutWeather`, `bareWeatherTopic`, `bareWeatherTiming`,
     `temperatureInPlace`); `weatherPlace`, which stops at the first place
     and ends each candidate at the next preposition, with `notAPlace`
     (home, work, school, languages); the wider `timePhrase` with
     `placeLikeTimes`; `nearTime` in `namedPlace`/`namedDestination`;
     `hasLocalPlaceCue`, `isDeveloperQuestion` and `languages`.
   - `Enigma/Search/SearchRouting.swift`: `placeWords` is split into
     `areaPlaceWords` and `ambiguousPlaceWords`, and `placeWords` is now
     internal. `localPlace`, `localAmbiguousPlace` and
     `localUnambiguousPlace` end at `(?![\w/-])`. The `area` lookahead skips
     languages. `localAmbiguousInArea` is new, and `howTo` is now internal.
     `webQuery` rewrites "local <word>" only when there is a city.
   - `EnigmaTests/SearchRoutingTests.swift`: the brief's rows and the
     round-1 rows, the two finding-4 questions in
     `testWeatherHasExactlyOneWayToFindItsPlace`, `testLongDraftStaysFast`,
     and the `webQuery` cases.
   - `Enigma/Search/WebSearchPolicy.swift`: `needsFreshInformation` also
     counts `asksAboutWeatherNow` (D20).
   - `EnigmaTests/WebSearchTests.swift`: `testWrittenQueryCannotChooseRoute`
     uses "latest cafes near me" and asserts `request.recency == nil`.
   - `docs/superpowers/specs/2026-10-27-f29-on-device-web-search-design.md`:
     an "Amended overnight" note in §6.1 for D10–D12.
   - `overnight-decisions.md`: D7–D9 and D13–D14 (D10–D12 are the
     orchestrator's).
3. **Decisions** (decision log D7–D30; D10–D12, D15, D16, D18, D20, D22, D24, D25, D27 and D29 are the orchestrator's
   round-1 rulings, D11 reopens D7 for parts of the day, and D13 replaces
   D9's trailing-time cut):
   - **D7:** the times spec §6.1 adds (noon … halloween) and home, work and
     school leave the current location in use; CP1's times (months,
     weekdays, "the weekend", "an hour") still block it, so CP1's rows
     "will it snow in december" and "what's the forecast for the weekend"
     stay on the web route (owner decision 2 of 2026-10-27). Before CP1b,
     every new time row routed to weather with the time as the named place
     ("noon", "christmas", "home", "work"), never with neither.
   - **D8:** `testWebQueryDropsCueWithoutCity`'s "local cafes" → "cafes"
     assertion now expects "local cafes", as spec §6.1 says.
   - **D9:** the place stops before "in/at/for/near <time>"; "forecast"
     stays a now word because `testLocationIntentOnlyUsesNearbyQuestions`
     pins "Weather forecast" with location.
   - Task 1b.1, the F32 and F30 names, all found as the plan says:
     `NativeToolPlan`, `NativeToolPart`, `SearchBackend`
     (`Enigma/Chat/AssistantToolbox.swift`); `AssistantToolbox` (same file);
     `WebSearchTool` (`Enigma/Search/WebSearchTool.swift`); `submitNative`
     and `SavingMessagesGate` (`LocalChatViewModel.swift`; the gate is
     `private`); `ChatSession.holdsMessageText` (`ChatDomain.swift`, a
     `Bool?`); `NativeToolsEvalTests`; `EnigmaTests/Fixtures/F32/eval.jsonl`;
     `ProviderSearch` (`ChatDomain.swift`); `ProviderSearchPart`
     (`Enigma/Cloud/NativeWebSearch.swift`); `scripts/web-search-queries.json`
     and `scripts/evaluate-native-search.py`. One difference worth knowing:
     `NativeToolPart`'s search case carries its backend, `.search(SearchBackend)`
     (`.enigma` or `.provider`), not a bare `.search`.
4. **Verification** (`scripts/verify-xcode.sh`, logs outside the repo):
   - RED: `test -only-testing:EnigmaTests/SearchRoutingTests
     -only-testing:EnigmaTests/WebSearchTests`: 71 executed, 38 failed, all
     on the new rows and `webQuery` cases. The recency assertion and the
     finding-4 rows already passed (they pin existing behavior).
   - GREEN: the same, 71 executed, 0 skipped, 0 failed.
   - Wider effect: every class in `ComposerIntentTests.swift`
     (`MessagesIntentPolicyTests`, `ThinkIntentTests`,
     `SelectionIntentPolicyTests`, `ComposerIntentResolveTests`,
     `ComposerIntentChipsTests`), `ComposerIntentPhrasingTests` and every
     class in `MessagesTests.swift`: 99 executed, 1 skipped, 0 failed. The
     phrasing corpus has no differences.
   - Mutants, in a scratch copy: `namedPlace: place` fails `testRoutes` and
     `testWeatherHasExactlyOneWayToFindItsPlace` ("weather near me for the
     marathon", "forecast nearby for hiking"); recency from
     `contextualQuery` fails `testWrittenQueryCannotChooseRoute` ("week").
   - `build`: succeeded.
   - After review round 1: `SearchRoutingTests` + `WebSearchTests` failed
     23 assertions before the fixes (the new rows, the `pub/sub` `webQuery`
     case and `testLongDraftStaysFast`, which took 10.2 s); after the fixes,
     72 executed, 0 skipped, 0 failed (`testLongDraftStaysFast` ran in
     0.025 s). The wider classes ran again: 99 executed, 1 skipped, 0 failed,
     and the phrasing corpus still has no differences.
   - Round-1 mutants: removing `!matches(notAPlace, place)` fails
     `testRoutes` ("home", "spanish"); removing noon…halloween from `times`
     fails `testRoutes` ("noon").
   - Review: round 1 (Opus, xhigh) found no Blockers and 7 Should fixes,
     all fixed test-first.
   - Review: round 2 found no Blockers and 6 Should fixes (D15), all fixed
     test-first. "Outside" counts only next to the topic word. "right
     now/now/later" end the place. D12 needs the question to start with
     "temperature" and excludes pronouns. Wider weather verbs and "chance of
     rain" are weather. "temperature near me" is weather. Business how-tos
     aren't nearby. Before the fixes: `SearchRoutingTests`, 6 executed,
     22 failures. After: `SearchRoutingTests` + `WebSearchTests`, 72
     executed, 0 skipped, 0 failed; the wider classes, 99 executed,
     1 skipped, 0 failed; no phrasing-corpus differences.
     `testLongDraftStaysFast` now rejects every candidate before "paris"
     (0.036 s).
   - Review: round 3 found no Blockers and 4 Should fixes, plus the
     orchestrator's fifth fix (D18, D19), all made test-first. "Temperature
     now" questions are weather again. A month or season after in/during is
     background. "what's the weather" uses the location. A city before
     "weather" is the named place. Rows were added that kill the two
     surviving mutants (removing `stop.pointee = true`, and removing the
     developer veto in `localAmbiguousInArea`); both were confirmed killed
     in scratch copies. `testLocationCheckReadsTheQuestionWithoutCommands`
     now uses "What is weather?" (D19). Before the fixes:
     `SearchRoutingTests`, 22 failures. After: `SearchRoutingTests` +
     `WebSearchTests`, 72 executed, 0 skipped, 0 failed; the wider classes,
     99 executed, 1 skipped, 0 failed; no phrasing-corpus differences.
   - Review: round 4 found no Blockers and 4 Should fixes (D20, D21), all
     made test-first:
     - the "temperature now" questions match only the whole question
       (`temperatureNow`), so a phrase inside another question no longer
       sends the location;
     - `temperatureInPlace` allows like/now before in/at/near;
     - "<city> weather" counts as fresh information again
       (`needsFreshInformation` checks `asksAboutWeatherNow`);
     - descriptive words before "weather" are never the city.
     Six mutants were killed in scratch copies: no `timePhrase`, no
     `notAPlace`, no developer-word check, no `$`, `{0,5}`, and no `^` on
     `temperatureNow`. Before the fixes: `SearchRoutingTests`,
     18 failures. After: `SearchRoutingTests` + `WebSearchTests`,
     73 executed, 0 skipped, 0 failed; the wider classes, 99 executed,
     1 skipped, 0 failed; no phrasing-corpus differences.
   - Review: round 5 found no Blockers and 3 Should fixes, plus D22's
     freshness exception (D22, D23). All were made test-first:
     - a descriptive word rejects the city only as its first word, so "bay
       area" and "long beach" are cities again (the round-4 location leak);
     - the temperature patterns take repeated modifiers;
     - web rows pin `temperatureNow`'s second alternative;
     - weather-software questions don't count as fresh through the weather
       rule.
     After the fixes: `SearchRoutingTests` + `WebSearchTests`, 74 executed,
     0 skipped, 0 failed; the wider classes, 99 executed, 1 skipped,
     0 failed.
   - Regression probe: the reviewers' harness, copied to
     `/private/tmp/claude-501/cp1b-probe-worker`. It compiles
     `LocationIntent`, `SearchRouting` and `WebSearchPolicy` with stubs and
     runs about 740 questions. Against cc48a19, 249 rows changed route,
     location or place, and 25 more changed freshness only. I reviewed every
     row. The intended changes are the ones spec §6.1 and D7–D22 describe:
     - bare topic words are web;
     - "local <word>" is a nearby cue;
     - times, home, work and school use the location;
     - candidates are tried in order and end at the next preposition;
     - months and seasons are background;
     - "temperature in <city>" and "<city> weather" name the place;
     - "is it raining" and similar are weather;
     - named-place weather is fresh.
     About 30 unintended changes were fixed (D23). The rest are listed for
     CP7 below. The probe's 16 long-draft inputs (80–98K characters) take
     0.09 s or less each.
   - Review: round 6 found no Blockers and 3 Should fixes (D24, D26), two of
     them location leaks, all made test-first:
     - "right now", "this weekend" and parts of the day count for a bare
       topic word only as the whole question or with a place;
     - "forecast" is a weather word only after a topic word or leading the
       question;
     - rows were added that kill round 5's three surviving mutants.
     After the fixes: `SearchRoutingTests` + `WebSearchTests`, 74 executed,
     0 skipped, 0 failed. The wider classes: 99 executed, 1 skipped,
     2 failed. Both failures are `ComposerIntentChipsTests` key-window
     timeouts while the screen is locked. They failed again when rerun
     alone, don't touch routing, and are recorded as environment failures
     (D25, D26).
   - Probe after round 6: against cc48a19, 252 rows changed route, location
     or place, and 24 changed freshness only. Since round 5, 3 rows changed,
     all intended: "is there rain in the forecast", "sales forecast for q3"
     and "what's my cpu temperature right now" went from weather to web.
     The slowest long-draft input takes 0.23 s.
   - Review: round 7 found one location leak and one round-6 regression
     (D27, D28), fixed test-first:
     - "forecast" left the nearby cues, and "local" joined the forecast
       topic words, so "what's the local forecast for denver" is weather for
       Denver with no location;
     - "today's/tomorrow's/this weekend's forecast", "check/show me the
       forecast", "how's the forecast looking" and "forecast for this
       weekend" use the location and count as fresh again;
     - rows kill the four mutants that would reopen round 6's leaks, and
       each was confirmed killed.
     After the fixes: `SearchRoutingTests` + `WebSearchTests`, 75 executed,
     0 skipped, 0 failed. The wider classes: 99 executed, 1 skipped,
     2 failed; both are the same `ComposerIntentChipsTests` key-window
     timeouts (D25). Probe: 252 rows changed vs cc48a19 and 24 changed
     freshness only; none changed since round 6. The 98 rows that newly use
     the location all fall in accepted categories (D28).
   - Review: round 8 found one location leak (D29, D30), the last fix, with
     no round 9. In a forecast-only question, a home, work, school or time
     word after in/at/for/near is a time only when it stands alone, so
     "what's the forecast for home prices / school enrollment / thanksgiving
     sales" goes to web with no location. "new year's eve/day" is a near
     time. My port matches the reviewer's prototype on 1,138 questions,
     except the intended "new year's eve" row. The 738-question probe is
     unchanged since round 7.
   - Final checks, after round 8:
     - `test -only-testing:EnigmaTests/SearchRoutingTests
       -only-testing:EnigmaTests/WebSearchTests`: 75 executed, 0 skipped,
       0 failed.
     - The wider classes (`ComposerIntentTests.swift`,
       `ComposerIntentPhrasingTests`, `MessagesTests.swift`): 99 executed,
       1 skipped, 2 failed. Both are `ComposerIntentChipsTests` key-window
       timeouts (environment).
     - `build`: succeeded.
     - `analyze`: succeeded, with no warnings in the changed files.
     - Full suite: `test -test-timeouts-enabled YES
       -default-test-execution-time-allowance 60`, with the screen locked.
       1,656 tests ran: 1,544 passed, 31 skipped and 81 failed, counted per
       test case; the runner restarted once after a timeout. All 81
       failures are environment failures (D25, D31, D32): hosted UI tests in
       AppCommandTests (2), ChatCopyTests (2), ComposerIntentChipsTests (2),
       EnigmaCompactPanelTests (15), EnigmaConversationTests (18),
       EnigmaMainWindowTests (29), FileModeUITests (1), ScreenCaptureTests
       (1) and ScreenViewTests (11). None touch Search or routing. 77 time
       out waiting for a control or the key window. The `isKeyWindow`
       assertion and the two character-animation tests fail the same way on
       cc48a19. The FileModeUITests case hung and was stopped by the time
       allowance; its class passes 18 of 18 alone. GitHub Actions CI is the
       check for these.
     - An earlier full run without time limits hung on
       `LocalVisionTests.testGuidedDownloadViewShowsChoicesWithoutFilePickers`
       and was stopped (D31).
5. **Limitations:**
   - `LocationIntent.needsLocation` also feeds automatic search
     (`WebSearchPolicy.needsFreshInformation`) and F30's provider-search
     location on capable cloud turns (`providerSearchLocation`). So "local
     gyms" and the noon/home/work weather questions now ask for location
     there too (after the provider is allowed on its card), and bare-topic
     questions such as "what is the temperature to bake salmon" no longer
     do. This is the approved `needsLocation` change; no other capable-model
     behavior changed.
   - `needsLocation` also changed on purpose beyond "local <place word>"
     (D15). The location is now used for "is it raining", for the
     home/work/time weather questions (D7, D11), and for "cafes near me open
     at lunch", because times are no longer places. CP1 had wrongly dropped
     the location for these.
   - "wine bars in brooklyn" and "parks in denver" take the web route: the
     ambiguous words need a nearby cue or "local" (spec §6.1).
   - The developer-word and language lists (D14) are finite; an unlisted
     word ("best local library for elixir") still asks for location.
   - A weather place that contains "in/at/for/near" as a word is cut there
     (D13).
   - `testLongDraftStaysFast` has a loose 2 s timing bound (D13).
   - For CP7 (reviewer round 3 edge cases, left by D16):
     - "local <place word>" in non-nearby questions ("why should i support
       local coffee shops", "local bar association") still asks for the
       location.
     - "is there rain in the forecast" gives the place "the forecast".
     - "is it raining men lyrics" routes to weather.
     - "swift weather app tomorrow" routes to weather with the location.
     - The city-before-"weather" rule can take an unlisted descriptive word
       as a city ("gloomy weather today"). Geocoding then fails, and the
       search falls back to the web.
     - Places named after a season ("spring texas", Fall River, Winter
       Park) go to web, since a season after "in" is background.
     - "weather today nyc" and "nyc weather for today" use the current
       location.
     - Spec-approved "local <place word>" still asks for the location in
       questions that aren't about finding a place: "are local gyms better
       than chains", "local hospital jobs", "local hotel tax rate", "names
       for a local coffee shop", "should i buy from local bakeries" and
       "the local pub in the uk".
     - "the …" weather places geocode to nothing and fall back to the web:
       "is it raining at the stadium", "in the city", "in the mountains",
       "what's the weather like in the game".
     - "best running shoes for rain today" routes to weather with the place
       "rain".
     - "why is it raining frogs" routes to weather.
     - "local park in unity" goes to web, since "unity" is a developer
       word.
     - Descriptive words before "weather" that aren't listed still become a
       city, for example "muddy weather today" (D23).
     - A forecast-led question about a non-place ("what is the forecast for
       q3 sales") routes to weather with a junk place. It uses no location
       (D26).
     - "nyc forecast", "vail snow this weekend" and "seattle rain right now"
       go to web rather than weather for that city (D26).
     - "forecast for chicago" goes to web (D28).
     - "raining right now" goes to web: there's no verb, and it isn't one
       of the whole-question forms.
     - Pollen, surf, UV and wind forecasts go to web.
     - "today's forecast vs actual sales" uses the location, as it did at
       cc48a19.
   - Any question holding "forecast" plus a place-like phrase ("sales
     forecast for q3") still routes to weather, as in CP1 (D9).
   - "rainy", "snowy" and "temperatures" aren't topic words; the spec's list
     is exact.
6. **For the next checkpoint:**
   - `SearchRouting.placeWords` is internal and holds every place word;
     `LocationIntent`'s `nearbyCue` is built from it, so a word added there
     becomes a "local <word>" cue for both routing and location.
   - `weatherPlace` returns the first non-time, non-home/work/school
     candidate, trimmed of punctuation; it can still be a non-place
     ("the marathon", "hiking") when no location cue is present, and CP6's
     geocoding failure falls back to web search.
