# CP0b: Second probe — the search sites from another network

Read [agent-workflow.md](agent-workflow.md), the spec (§2, §6.4, Delivery's
"Open questions for CP0b"), and [CP0's Hand-off](cp0-spike.md#hand-off) in
full.

## Goal

CP0 ran on one network on one afternoon. Mojeek answered with a captcha and
then 403s (and later blocked that network for a real browser too),
Startpage challenged every search, and DuckDuckGo challenged 5 of 20.
CP0b repeats the acceptance check from another network, settles
DuckDuckGo's region and header set, and checks Open-Meteo's geocoding, so
the owner can fix the site lineup before CP2 builds the ports. **No product
code comes out of this checkpoint.**

- Probes live in a scratch folder outside the repository. Swift scripts
  (as CP0 used, for URLSession) and `curl` for Open-Meteo.
- Only the Hand-off, any new sanitized fixtures and their README lines are
  committed.

## Starting point

- **The worktree** (outside `~/Documents`; `git worktree list` shows it) on
  `feat/f29-on-device-search`, at CP1 plus a local merge of an older `main`
  (`aac6d48`, not pushed). **First, merge `main` into the branch**
  (`git fetch origin && git merge origin/main`), the one merge this plan
  allows. It brings F32, F30 and these rewritten docs; the CP0 and CP1
  briefs on `main` already hold the branch's Hand-offs, so their conflicts,
  if any, resolve to `main`'s side. Push the branch after the merge.
- **CP0's probe,** described in its Hand-off (Q4, Verification): 20 rounds,
  5 s apart, 4 rotating queries, Safari's headers with the version read from
  the installed Safari. Its scripts aren't in the repository; write them
  again from that description.
- **The two header sets** from CP0's Q4(e):
  - **A, the probe's:** `User-Agent`, `Accept`, `Accept-Language`,
    `Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode`, `Sec-Fetch-Dest`,
    `Priority: u=0, i`, and `Origin` plus `Referer` on POSTs;
  - **B, CP2's planned `SafariHeaders.standard`:** the same without
    `Origin` or `Priority`, `Sec-Fetch-Site: none`, and `Referer` only to
    Startpage.

  The owner approved probing with these two sets when approving the spec
  (2026-10-29). Don't try any other header change to get past a block: that
  stays the owner's call, as CP0 said.
- **The network:** the owner runs the probe on a network other than CP0's
  (for example at home). The worker writes the probe and hands the owner
  the command; record which network type it was (home, office, mobile
  hotspot), never an address.

## Tasks

### Task 0b.1: Acceptance (Q1)

**Owner-run.** About 120 requests per site across both header sets.

- [ ] **Write the probe:** for each of DuckDuckGo, Mojeek and Startpage
  (Startpage's token request plus search counts as one), run CP0's 20
  rounds with header set A, wait 2 minutes, then 20 with set B. Same 4
  queries as CP0 ("how do vaccines work", and CP0's other three from its
  scratch notes or three of the same kind). Stop a site early after 3
  consecutive blocks with a set, and move on.
- [ ] **Record** per site and set: status codes, result counts, block
  markers (CP0's list), median latency.
- [ ] **Hand the owner the command** and wait for its output folder.

### Task 0b.2: DuckDuckGo's region (Q2)

**Owner-run,** in the same run: 4 extra DuckDuckGo requests.

- [ ] **Send** "best pizza" and "news today" twice each: with `l=us-en`
  (ddgs's form field) and with `kl=us-en`. Record the echoed
  `<input name="kl">` value and whether results differ (count of shared
  URLs among the top 10).

### Task 0b.3: Parsing Mojeek and Startpage (Q3)

Only if a site returned results pages in Task 0b.1.

- [ ] **Save** one results page and one no-results page per site
  (sanitized as CP0 did: tokens, session values, geo-IP points, per-request
  IDs), as `mojeek-results.html`, `mojeek-no-results.html`,
  `startpage-results.html`, `startpage-no-results.html`.
- [ ] **Parse** each with `XMLDocument(xmlString:options: [.documentTidyHTML])`
  after decoding, and ddgs's XPaths from spec §2. Record whether titles,
  links and bodies match the page as a browser shows it. If tidy breaks the
  XPaths (CP0 expected this for Startpage), say so: SwiftSoup or a libxml2
  wrapper would be a new dependency and an owner decision.

### Task 0b.4: Open-Meteo geocoding (Q4)

- [ ] **Run** spec §6.4's geocoding request 5 times each for "Paris",
  "Springfield", "Pariss" and "東京" with `language=en` and the Mac's
  language. Record the shape (name, admin fields, country, latitude,
  longitude, timezone), latency, and what comes back for each.
- [ ] **Save** `open-meteo-geocoding-paris.json` as a fixture.

### Task 0b.5: The owner's lineup

- [ ] **Write the Hand-off,** then ask the owner to decide, with your
  recommendation and the evidence:
  1. keep, drop or replace Mojeek (primary) and Startpage (backup);
  2. which header set CP2 sends;
  3. whether DuckDuckGo gets `kl`.

  If Mojeek and Startpage both drop, say what that leaves (DuckDuckGo and
  Wikipedia, one index, no backup) and whether the spec's agreement score
  and Startpage rule still make sense. Record the owner's answers in the
  Hand-off and the progress log; CP2 follows them.

## Exit criteria

- Every row of the findings table is filled in, and the owner's three
  decisions are recorded.
- New fixtures are sanitized, with README lines.
- `git status` shows only this brief, the plan's progress log, and the
  fixtures.

## Reviewer checklist

- **Fixtures:** no IP address, geo-IP point, session value, account or
  username. Diff each against its raw capture's structure.
- **Evidence:** each answer follows from the recorded output; the network
  is described by type only.
- **No header variation** beyond sets A and B.
- **Never rerun a live probe.** Reason from the recordings.

## Hand-off

*Filled in by the CP0b worker.*

All probes ran on 2026-10-29, between 23:31 and 23:51 local time, on one
Mac (macOS 27.0.1, Safari 27.0.1) on a **home network** (CP0 ran on a
school network). Every search request went through an ephemeral
`URLSession`, no redirects followed, the Safari version read from the
installed bundle, `Accept-Language: en-US,en;q=0.9`.

| # | Question | Answer | Evidence | Decision for later checkpoints |
| --- | --- | --- | --- | --- |
| Q1 | Acceptance per site and header set, on another network | **DuckDuckGo: set A answers 15 of 20, as on CP0's network; set B is challenged after its first request. Mojeek and Startpage: blocked with both sets, from the first request.** | **Run 1** (set A, 2-minute pause, set B; sites in parallel each round, 5 s apart; 3 consecutive blocks stop a site for that set). **DuckDuckGo, set A:** 20 requests, 15 × HTTP 200 (median 605 ms, 28–30 KB, 10 results each, `kl` echoed as `wt-wt`) and 5 × HTTP 202 "bots use DuckDuckGo too" (median 63 ms). As on CP0's network, all 5 202s fell on "how do vaccines work", every time it was asked; the other three queries got 200 all 15 times. **DuckDuckGo, set B:** 1 × 200 (609 ms), then 3 × 202 on three different queries (median 56 ms), so the set stopped after 4 requests. **Run 2** (DuckDuckGo only, order reversed so set B goes first, started about 10 minutes after run 1's last request): set B again 1 × 200 (633 ms), then 3 × 202 on three different queries (median 47 ms). After the 2-minute pause, set A repeated run 1 exactly: 15 × 200 (median 628 ms, 10 results each) and 5 × 202 (median 54 ms), all 5 on "how do vaccines work". So set B's blocks follow the headers, not the order or leftover challenges. **Mojeek:** HTTP 200 `<title>Captcha` on every request, both sets (3 + 3, median 395 ms); on CP0's network the first request also got a captcha. **Startpage:** the homepage itself now returns the Anubis proof-of-work page (`<script id="anubis_challenge">`, HTTP 200, 22 KB) on every request with both sets (3 + 3, median 90 ms), so there is no `sc` token and no search was sent. CP0 got the token 20/20 and the challenge only on the search. Apart from its per-request challenge JSON, the page is byte-for-byte `startpage-challenge.html`. | Mojeek and Startpage refuse URLSession on a second, unrelated network, from the first request, so the block isn't the school network's reputation or CP0's own traffic. Lineup: see Owner. Had Startpage stayed, a homepage without the `sc` input but with `anubis_challenge` would be a block, not a layout change. |
| Q2 | DuckDuckGo `kl` vs `l` | **`kl` sets the region and `l` doesn't. For US queries from a US network the results barely change.** | "best pizza" and "news today", once with `l=us-en` and once with `kl=us-en`, 5 s apart. With set B (runs 1 and 2) 7 of 8 were challenged; the one answer (`l`) echoed `wt-wt`. **Run 3** (set A, region check only, starting about 20 s after run 2's last three set-B challenges): 4 × HTTP 200, 10 results each. With `l`, the page echoed `<input name="kl" value="wt-wt">` (All regions) and selected no region, like all 33 of runs 1–2's results pages; with `kl` it echoed `value="us-en"` and selected `<option value="us-en">`. Top 10 shared between `l` and `kl`: "best pizza" 10 of 10, same order; "news today" 10 of 10, one item moved. Both "best pizza" pages already listed pizza places in the network's own city, so DuckDuckGo localizes by IP address without either field. | `l` is ignored on two networks; `kl` is the field DuckDuckGo reads. The effect is invisible for a US user in the US and should show for other locales (unmeasured). Owner decides; if `kl`, CP2's live check confirms the echoed value, as its brief already says. |
| Q3 | Mojeek and Startpage parsing | **Not testable: neither site returned a results page.** | No Mojeek results page (captchas only) and no Startpage search at all (Q1). No `mojeek-results.html`, `mojeek-no-results.html`, `startpage-results.html` or `startpage-no-results.html` exists. The probe's parser (`XMLDocument(xmlString:options: [.documentTidyHTML])` after decoding, ddgs's XPaths) reproduced the fixtures README's expected values on `duckduckgo-results.html` and found 10 items with no empty titles or links on every 200 page in both runs, and 0 on every challenge page. | CP0's Q1 stands: `XMLDocument` is confirmed for DuckDuckGo only. If Mojeek or Startpage stays, its parser still needs a captured results page, and a tidy failure would still mean a new dependency (owner). |
| Q4 | Open-Meteo geocoding | **Works, about 0.5 s; typos and non-Latin names are the gaps.** | Spec §6.4's request (`count=1`, `language=en`), 5 times each, 1 s apart, `curl`, all HTTP 200; the 5 answers per name were identical apart from `generationtime_ms`. Median (range) per request: Paris 540 ms (516–734), Springfield 493 (490–739), Pariss 514 (478–836), 東京 689 (510–878); each is a fresh TLS connection. **Shape:** `results` array of `id`, `name`, `latitude`, `longitude` (5 decimals), `elevation`, `feature_code`, `country_code`, `country`, `country_id`, `admin1`–`admin4` with their `_id`s (only the levels that exist), `timezone`, and optional `population` and `postcodes`; no `results` key at all when nothing matches. **Answers:** "Paris" → Paris, admin1 "Île-de-France Region", France, 48.85341, 2.3488, Europe/Paris. "Springfield" → Springfield, Missouri, United States (the most populous Springfield, not Illinois's capital), America/Chicago. "Pariss" → **"Parisse", Nord-Est, Haiti**: no error, a different place. "東京" → no results. The Mac's only language is English, so the Mac's-language run equals `language=en`. Extra checks, same method: "東京" with `language=ja` and "東京都" with `language=en` → no results; "Tokyo" → Tokyo, Japan, Asia/Tokyo. | Spec §6.4's request works, well within its 2 s limit. Spec's example "Paris, Île-de-France, France" is really "Paris, Île-de-France Region, France": state `name`, `admin1` and `country` as returned. **For the owner (spec §6.4, CP6):** a misspelled place resolves silently to another place; CP6 should show the resolved name and country so the user can spot it (spec already states them in the excerpt), and could ask for `count` > 1 and prefer an exact name match. Place names in Japanese script (and probably other non-Latin scripts) find nothing, so they take spec §6.4's "I couldn't find ‹place›" path, or the web fallback on small models. Saved as `open-meteo-geocoding-paris.json`. |
| Owner | Lineup, header set, `kl` | **Drop Mojeek and Startpage; send header set A; send `kl`** (owner, 2026-10-29, each the worker's recommendation). | Q1: both refused every request on two unrelated networks from the first request, with both header sets, and neither produced a page to parse (Q3). Set A: 15 of 20 answered in both set-A runs, only one query challenged; set B: challenged after its first request in both orders. Q2: `kl` is the field DuckDuckGo reads. | **Lineup: DuckDuckGo and Wikipedia.** One web index and no backup: when DuckDuckGo is challenged or cooling down, a search has Wikipedia alone. CP2 skips Tasks 2.3 (Mojeek) and 2.4 (Startpage), their `SearchEngineID` cases, fixtures' tests, live checks and `UPSTREAM.json` entries, and Task 2.7's Startpage rule: the runner queries the primaries only, as CP2's brief says. Spec §3.3's agreement score still works unchanged but, with one site, reduces to DuckDuckGo's own order (weight 1.0 / position); CP3 keeps the formula so a later second site slots in, and drops the Startpage and Mojeek weights. Spec §2's "When Startpage runs" and its 2.5 s budget line no longer apply. **Header set A** replaces `SafariHeaders.standard`'s fields in CP2's Task 2.1: `Sec-Fetch-Site: same-origin`, `Origin` and `Referer` on POSTs, `Sec-Fetch-Site: none` on GETs, and `Priority: u=0, i`. **`kl=<region>`** replaces `l=<region>` in DuckDuckGo's form (Task 2.2); CP2's live check confirms the echoed value. |
| Owner | Cloud models' search (asked during CP0b, 2026-10-29) | **ChatGPT via Codex and Claude Code are the only cloud providers to design for, and they always use their provider's own search,** which the owner trusts more than Enigma's. | F30 already gives both their provider's search; CP0b's results (Q1) leave Enigma's search with one index. | CP5 and CP8 don't offer Enigma's `web_search` on ChatGPT or Claude Code turns where the provider's search runs; `find_places` and `get_weather` are still offered beside it, as spec §6.2 says. **F30's behavior stays as shipped** (owner, re-asked during CP0b after the worker first misdescribed it): **Don't allow** on F30's card in a chat with message text sends the question with no search at all, not even Enigma's (`NativeToolPlan.Inputs.searchDeclined`, `testRestartDeclinedHasNoSearch`); when the provider's search isn't available (plan, workspace policy or model), F30's fallback runs Enigma's `web_search`, which F29 makes keyless; an error after the reply has started is shown as an error. See `docs/Web-Search.md`. Other cloud providers need no extra F29 work. |

1. **Summary:** Reran CP0's acceptance probe from a home network with
   header sets A and B, checked DuckDuckGo's region field, and probed
   Open-Meteo's geocoding. DuckDuckGo behaves as on CP0's network with set A
   (15 of 20 answered, one query challenged every time, in both runs) and
   is challenged after one request with set B, in either order. Mojeek (captcha) and Startpage (proof-of-work
   on the homepage) refuse every request on this network too, so neither can
   be parsed and both look unusable through URLSession. DuckDuckGo reads
   `kl`, not `l`, for its region. Open-Meteo's
   geocoding works in about 0.5 s, but resolves typos to other places and
   finds nothing for Japanese place names. The owner dropped Mojeek and
   Startpage, chose header set A and `kl`, and confirmed that ChatGPT and
   Claude Code always use their provider's search, keeping F30's
   Don't-allow and fallback behavior as shipped. One code change: a
   derived `searchCity` restores the "Austin, TX" search city the merge
   had cut to "Austin".
2. **Files:**
   - `EnigmaTests/Fixtures/Search/open-meteo-geocoding-paris.json`: Task
     0b.4's fixture, saved as returned.
   - `EnigmaTests/Fixtures/Search/README.md`: its row, and the intro now
     says not every file is from CP0.
   - This brief's Hand-off, and the CP0b row of the plan's progress log.
   - Before the probe, the branch merge of `origin/main` (`81a77b8`,
     pushed), which the brief's Starting point asks for. One code conflict,
     plus fixes the merged code needed to compile and keep CP1's behavior:
     - `Enigma/Search/LocationService.swift` (the conflict): main's
       `ApproximateLocation` (F30's stored `city`, `region`, `countryCode`)
       plus CP1's rounded `latitude`, `longitude` and `coordinate`, and
       CP1's `unknownArea` as the default `area`. Taking main's side alone
       would have removed what CP1's search request uses.
     - **The one code change in this commit, approved by the owner:** the
       merge left `city` as main's stored MapKit `cityName` ("Austin"),
       where CP1 derived it from `area` ("Austin, TX"), so F29's search
       request lost the state that disambiguates "near me" for search
       sites (round-1 review). `ApproximateLocation.searchCity` now holds
       CP1's derived value (the area, or nil for `unknownArea`), and
       `LocalChatViewModel` sends it as `request.city`; F30's provider
       search keeps the stored `city`. In `WebSearchTests`, CP1's two
       fixtures are area-only again, `testApproximateLocationKeepsRoundedCoordinates`
       and `testUnknownAreaHasNoCity` check `searchCity`, and the new
       `testNearbySearchSendsTheAreaWithItsState` checks that area "Austin,
       TX" with city "Austin" sends "Austin, TX".
     - `EnigmaTests/NativeToolRequestTests.swift`: main's
       `NativeSearchProvider` fake implemented the pre-CP1
       `search(_:maximumTokens:)`; it now implements CP1's
       `search(_ request:)` and records `request.query`.
     - The plan, `cp0-spike.md` and `cp1-foundations.md` took main's side.
     - The merge sits on top of the earlier unpushed local merge `aac6d48`
       rather than replacing it, because the workflow allows no `reset`.
3. **Decisions:**
   - **Queries:** CP0's four, recovered from CP0's session: "swift
     concurrency actors", "how do vaccines work", "best hiking boots 2026",
     "東京 天気". Mojeek's cookies `arc=us; lb=en` and Startpage's form
     fields are CP0's.
   - **Header sets exactly as the brief defines them.** A: CP0's, with
     `Sec-Fetch-Site: same-origin`, `Origin` and `Referer` on POSTs only
     (`none` on GETs, as CP0 sent) and `Priority: u=0, i` on every request.
     B: no `Origin` or `Priority`, `Sec-Fetch-Site: none`, `Referer` only on
     Startpage's search. No other header change was tried.
   - **Runs 2 and 3** (beyond the brief, DuckDuckGo only, sets A and B
     only): run 1 sent set B straight after set A's five challenges, so set
     B's blocks could have been carry-over, and every region request was
     challenged. Run 2 sent set B first, then set A, then the region check
     with set B; run 3 sent the region check with set A. The owner chose to
     run them without a longer cool-down: run 2 started about 10 minutes
     after run 1's last request, and run 3 about 20 s after run 2's. In
     all, DuckDuckGo got 60 requests tonight.
   - **Early stop** counts a missing Startpage token as a block, so
     Startpage stopped after 3 homepage requests per set.
   - **Geocoding extras:** "東京" with `ja`, "東京都" and "Tokyo", because
     the Mac's language is English and the brief's second language run
     would have repeated `en`.
   - **No new block-page fixture:** Startpage's homepage challenge equals
     `startpage-challenge.html` outside its per-request JSON, and Mojeek's
     captcha matches `mojeek-captcha.html`'s markers, so neither adds a case.
4. **Verification:**
   - After the merge: `scripts/verify-xcode.sh test
     -only-testing:EnigmaTests/WebSearchTests
     -only-testing:EnigmaTests/NativeToolRequestTests
     -only-testing:EnigmaTests/SearchRoutingTests`: 152 executed, 0 skipped,
     0 failed.
   - The `searchCity` fix, test first: with the property added but not yet
     used, `WebSearchTests` failed 3 tests (the new one got "Austin"; two
     area-only fixtures got nil); after the call-site change, the same
     three classes ran 153 executed, 0 skipped, 0 failed.
   - Probes, in a scratch folder outside the repository (`<probes>`), output
     in `<out>`: `<probes>/run.sh home` (run 1: `swift <probes>/sites.swift
     <out>`, then the geocoding `curl` loop), `swift <probes>/sites.swift
     <out2> ddg-reversed` (run 2), `swift <probes>/sites.swift <out3>
     region-A` (run 3), and the geocoding extras with `curl`.
     `swift <probes>/parse.swift ddg --kl <pages…>` for result counts and the
     echoed `kl`.
   - The fixture holds only Open-Meteo's public record for Paris; checked
     for an IP address, coordinates other than Paris's, and request data.
     The raw Startpage pages hold the network's IP address and stay in the
     scratch folder.
   - Review: round 1 (Opus, xhigh) found no Blockers and 3 Should fixes:
     the merge's change to the search city (fixed with `searchCity`, see
     Files), evidence slips in this Hand-off (run 3's timing, Startpage's
     median, the results-page count, set B's latencies), and a stray table
     header. Round 2 found no Blockers and 2 Should fixes, both in the
     docs: the cloud Owner row misdescribed F30's Don't-allow behavior (the
     worker had misdescribed it when asking; the owner, asked again, kept
     F30's behavior), and the Interface map still named `.city`. Both are
     fixed; as small round-2 fixes, they weren't reviewed again. Each
     reviewer reran the three test classes (152, then 153 executed, 0
     failed), and round 2 mutation-tested `searchCity`.
5. **Limitations:**
   - One more network, one evening. Set B was challenged in both orders,
     and set A answered straight after set B's challenges (2 minutes later
     in run 2, 20 s later in run 3), but no run had a long cool-down.
   - `kl`'s effect on results was measured only for `us-en` from a US
     network, where IP-based localization already applies (Q2).
   - The Mac runs macOS 27.0.1, not 26.
   - Mojeek and Startpage parsing remains untested (Q3).
6. **For the next checkpoint:**
   - CP2 follows the Owner row: skip the tasks of any dropped site, as its
     brief's "The owner's lineup comes first" says.
   - DuckDuckGo challenged "how do vaccines work" every time on two
     networks: expect some queries to be challenged consistently, and CP2's
     live check shouldn't use that query as its success case.
   - `ApproximateLocation.city` is now F30's stored MapKit city
     ("Austin"), for provider search. What CP1's brief calls the location's
     `city` for search sites is `searchCity` ("Austin, TX",
     nil for an unknown area); `WebSearchRequest.city` is filled from it.
     Build `SearchRouting.webQuery(_:city:)` and the weather excerpt from
     `searchCity`, not `city`. This commit updates the plan's Interface map
     to match. **Proposed for CP1's brief** (not edited here, per the
     workflow): its Interface block's `var city: String? { … nil when area
     == unknownArea }` is now `searchCity`, and `city` is F30's stored
     value.
   - Open-Meteo's geocoding: see Q4 for the shape and gaps (CP6).
