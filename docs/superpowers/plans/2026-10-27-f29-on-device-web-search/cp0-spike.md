# CP0: Spike — answer the open questions

Read [agent-workflow.md](agent-workflow.md) and the spec in full. The spec's
"Open questions for CP0" list is this checkpoint's scope.

## Goal

Answer the spec's nine open questions with throwaway probes, so later
checkpoints build on facts. **No product code comes out of this checkpoint.**

- Probes live in a scratch folder outside the repository.
  `scripts/selection-probe.swift` shows how a standalone Swift script sets up
  AppKit and a run loop, which `WKWebView` and MapKit need.
- Only two things are committed: this brief's Hand-off with the findings,
  and the sanitized fixtures from task 0.1 and task 0.5.

## Starting point

- Nothing for F29 exists yet. Brave (`Enigma/Search/BraveSearchClient.swift`)
  serves every route.
- ddgs reference: v9.16.1 (2026-10-23), `main` at `8e749591`. The engine
  files are in `ddgs/engines/`; read them on GitHub, don't install ddgs.

## Tasks

### Task 0.1: Search-site acceptance and fixtures (Q4, Q5, Q6)

- [ ] **Write the probe.** One Swift script that sends spec §2's requests
  with the exact Safari headers. Use an ephemeral `URLSession` with no cookie
  storage, and don't follow redirects. Cover:
  - DuckDuckGo: POST;
  - Mojeek: GET with the `arc` and `lb` cookies;
  - Startpage: the homepage for the `sc` token, then the POST.
- [ ] **Run it.** 20 searches per site, at least 5 s apart. Queries:
  "swift concurrency actors", "how do vaccines work", "best hiking boots
  2026" and "東京 天気". Record, for each request:
  - HTTP status, body size and latency;
  - whether the page is a block page: DuckDuckGo's 202, a bot check, or a
    captcha.
- [ ] **Answer Q5 and Q6.**
  - Q5: are DuckDuckGo's result links direct, or `//duckduckgo.com/l/?uddg=`
    wrappers?
  - Q6: does one Startpage `sc` token work for two searches 30 s apart, and
    what's the median latency of token plus search?
- [ ] **Save the fixtures** into `EnigmaTests/Fixtures/Search/`:
  - `duckduckgo-results.html` (results that include an ad if any appear),
    `mojeek-results.html`, `startpage-results.html`;
  - one no-results page per site, from the query "qzxv flarbnok 9183":
    `duckduckgo-no-results.html` and the Mojeek and Startpage equivalents;
  - every block page you met, for example `duckduckgo-blocked.html`;
  - `startpage-home.html`, holding the `sc` input.
- [ ] **Sanitize before saving.** Search each file for your public IP
  address, city, account names and username, and replace any you find with
  `REDACTED`. Then write `EnigmaTests/Fixtures/Search/README.md` with one
  line per file: source URL, date, query, and what was redacted.

### Task 0.2: Parsing (Q1)

- [ ] **Parse.** Run every saved results page through
  `XMLDocument(data:options: [.documentTidyHTML])`, then the ddgs XPaths from
  spec §2. Join text the way ddgs does: every text node, with whitespace
  collapsed to single spaces.
- [ ] **Compare.** Check the item count and the first three titles, links and
  snippets against the page itself (read the HTML or open it in a browser).
  Note every mismatch.
- [ ] **If any XPath fails,** write down the equivalent SwiftSoup CSS
  selectors on paper. Don't add the package. Mark Q1 **owner decision
  needed**.

### Task 0.3: WebKit (Q2, Q3)

- [ ] **Build the probe:**
  - a `WKWebView` configured as spec §4 describes;
  - a local `NWListener` on 127.0.0.1 that counts incoming connections;
  - a test page, loaded with `loadHTMLString(_:baseURL: nil)`:

    ```html
    <p id="a">x</p>
    <script>document.getElementById('a').textContent = 'RAN'</script>
    <img src="http://127.0.0.1:PORT/i.png">
    <iframe src="http://127.0.0.1:PORT/f"></iframe>
    <link rel="stylesheet" href="http://127.0.0.1:PORT/s.css">
    ```

- [ ] **Record these results:**
  - Q2: `callAsyncJavaScript("return document.getElementById('a').textContent", in: nil, in: .world(name: "EnigmaExtract"))`
    returns `x`. That means the page's script didn't run and Enigma's did.
  - Q3: the listener counts 0 connections. As a control, a run without the
    rule list counts at least 1.
- [ ] **Try Readability.** Load Readability.js 0.6.0 from the `0.6.0` tag of
  github.com/mozilla/readability into the same world. Record that `parse()`
  returns content for a saved news article.

### Task 0.4: MapKit (Q7)

- [ ] **Place search.** Run `MKLocalSearch` for "coffee" in a 5 km region
  around 41.88, -87.63. List which `MKMapItem` properties are filled in on
  macOS 26: name, `pointOfInterestCategory`, `phoneNumber`, `url`,
  `addressRepresentations`, `timeZone`. Note whether any opening-hours
  property exists.
- [ ] **Geocoding.** Run `MKGeocodingRequest` for "Paris". Record the
  coordinate and the address text it returns.
- [ ] **Terms.** Find the Apple terms that cover showing MapKit search results
  as text without a map. Record the document's name, its link, and a quote of
  at most 15 words. If the terms forbid it, mark Q7 **owner decision needed**.

### Task 0.5: Open-Meteo (Q8)

- [ ] **Measure.** Request spec §6's URL for 41.88, -87.63 with US units, 5
  times. Record the status, the latency, and that every requested field is
  present.
- [ ] **Save** one response as
  `EnigmaTests/Fixtures/Search/open-meteo-chicago.json`.

### Task 0.6: Lemmas (Q9)

- [ ] **Run `NLTagger` with `.lemma`** on one sentence each in English,
  French, German, Spanish, Italian, Portuguese and Japanese, with the network
  off.
- [ ] **Record** which languages return lemmas for their content words.

## Exit criteria

- All nine rows of the findings table below are filled in.
- The fixtures and their README are in `EnigmaTests/Fixtures/Search/`.
- No probe code is left in the worktree.
- `git status` shows only this brief and the fixtures.

## Reviewer checklist

- **Rerun the probes.** Repeat the WebKit probe (0.3) and the parsing probe
  (0.2) from the worker's notes, and confirm the recorded answers.
- **Check the fixtures** for personal data, and that each README line
  matches its file.
- **Check every decision** follows from the evidence, and that every
  "owner decision needed" is clearly marked.

## Hand-off

*Filled in by the CP0 worker.*

All probes ran on 2026-10-27 on one Mac (macOS 27.0.1, Safari 27.0.1, Xcode
with the macOS 27.0 SDK) on a single shared network. The app targets 26.0;
nothing here was run on 26.

| # | Question | Answer | Evidence | Decision for later checkpoints |
| --- | --- | --- | --- | --- |
| Q1 | Does `XMLDocument` match ddgs's XPaths? | **Yes for DuckDuckGo, provided the page is decoded first. Mojeek and Startpage unconfirmed; Startpage likely fails.** **Owner decision needed (likely), tied to Q4(b):** keeping Startpage probably means SwiftSoup or a libxml2 wrapper, a new dependency. `XMLDocument(data:options: [.documentTidyHTML])` ignores DuckDuckGo's `http-equiv` UTF-8 declaration and treats the bytes as ASCII (`characterEncoding` is `us-ascii`), so every non-ASCII character (Japanese, em dashes, "♥") was dropped or garbled. Decoding to a `String` and using `XMLDocument(xmlString:options: [.documentTidyHTML])` fixes it. | DuckDuckGo fixtures: 10 items each, no empty titles or links. All 10 rows of each fixture equal the page's `result__a` and `result__snippet` text, Japanese included (reviewer checked them against Python's HTML parser). 0–3 ms per page. Block, captcha and challenge pages give 0 items. Startpage's `sc` XPath returns two `sc` inputs from one `form#search`, because tidy nests the unclosed footer form inside it (same token; the first is used). Tidy nesting forms is worth knowing for CP2. No Mojeek or Startpage results page could be captured through URLSession (Q4). Startpage's result XPaths matched a live results page in a browser (10 items), but that is the browser's DOM, not `XMLDocument`. **Tidy restructures HTML5 markup** (reviewer's synthetic tests): `<div class="result css-1"><a href><h2>T</h2></a></div>` becomes `<h2><a href>T</a></h2>`, so Startpage's `[./a]` item XPath matches nothing; `<a><div>…</div></a>` becomes an empty `<a>` followed by the div; `article`, `section` and `main` are unwrapped. Mojeek-like `ul/li/h2/a` markup survives. | Keep `XMLDocument` for DuckDuckGo; `SERPDocument` decodes, then parses the `String`. Pin it with the Japanese fixture. Before CP2 relies on `XMLDocument` for Mojeek or Startpage, it must parse a captured results page from that site with it. If tidy breaks the XPaths, Q1's fallback (SwiftSoup or a small libxml2 wrapper) is an **owner decision**. Startpage's markup (`<a>` around `<h2>`) is likely to trip tidy. The equivalent SwiftSoup CSS selectors, on paper: Startpage items `div[class*="result css"]:has(> a)`, title `h2`, link `> a[href]`, body `p`; Mojeek items `ul[class*=results] > li`, title `h2`, link `h2 > a[href]`, body `p.s`; DuckDuckGo items `div[class*=body]`, title `h2`, link `> a[href]`, body `> a`. All three sites declare UTF-8 (DuckDuckGo with `http-equiv`, Mojeek with `meta charset`, Startpage with `charSet`), so `SERPDocument.init?(html: Data)` can decode inside: UTF-8, falling back to the declared charset. No interface change; spec §4's encoding order is for `PageReader`'s result pages. |
| Q2 | Do Enigma's scripts run with page JavaScript off? | **Yes.** | `callAsyncJavaScript(…, contentWorld: .world(name: "EnigmaExtract"))` returned `x` with `allowsContentJavaScript = false`; the control with page JavaScript on returned `RAN`. Readability 0.6.0 and `Readability-readerable.js` (files checked against the `0.6.0` tag), loaded with `evaluateJavaScript(_:in:contentWorld:)` into that world, parsed a saved BBC News article in 16 ms: title correct, `lang` `en-GB`, 2,977 characters, `isProbablyReaderable` true. `byline` was polluted ("1 hour agoShareSave… Nick JohnsonCorrespondent"), and `siteName` and `publishedTime` were null. `typeof Readability` in the page world stayed `undefined`. The reviewer also ran CP4's planned single `callAsyncJavaScript` holding the library sources followed by the extraction code: it works too (same article, 2,977 characters, 59 ms). | Spec §4 works as written. Both loading styles work: library sources and the extraction in one `callAsyncJavaScript`, as CP4's brief plans, or the libraries through `evaluateJavaScript` and then `callAsyncJavaScript`. Only splitting the library and the call across two `callAsyncJavaScript` calls fails, because each call's body is wrapped in a function. CP4 chooses. `EnigmaExtract.js` still needs a date fallback and a site-name fallback (for example `og:site_name` or the host), and shouldn't trust Readability's byline. **JSON-LD isn't in the DOM** (reviewer, round 2): with `allowsContentJavaScript = false`, WebKit leaves every `<script>` element out of the DOM, `application/ld+json` included, and `DOMParser` in the isolated world finds none either. The BBC article publishes its date and publisher only in JSON-LD (its meta has `article:modified_time`, not `article:published_time`), so spec §4's JSON-LD date can't be read from the DOM. Passing the page HTML to `callAsyncJavaScript` as an argument and scanning its `ld+json` blocks as a string in the isolated world worked: it returned the date and "BBC News", and still runs only in the WebContent process. Also, `<noscript>` content becomes live DOM with page JavaScript off (the article has 3), which Readability will see. CP4 should use the string scan; dates from meta tags alone would depart from spec §4 and need the **owner**. |
| Q3 | Does the block-all rule stop every load? | **Yes.** | Sealed view: 0 connections to the local listener from the `img`, `iframe` and `stylesheet`. Control without the rule list: 2 connections. The navigation delegate cancelled the iframe navigation in every run. The reviewer tried 16 more load vectors against the sealed view (preload, preconnect, prefetch, `srcset`, `picture`, video `poster`, `object`, `embed`, inline-style `url()`, `@import`, `@font-face`, SVG `image`, `input type=image`, `<base href>`, meta refresh, iframe `srcdoc`): 0 connections; without the rule list, 11 of them connected (meta refresh, `object`, `embed` and `srcdoc` are stopped by the delegate alone, and prefetch never connects). In the first reviewer's log the sealed `preload` row shows "(no data)": that was the previous test's preconnect socket closing, and `preload` alone gives 0. | Use the `url-filter: ".*"` rule plus the cancelling delegate; no HTML stripping needed. |
| Q4 | Do the sites accept URLSession with Safari headers? | **DuckDuckGo partly; Mojeek and Startpage no.** **Owner decision needed.** | 20 rounds, 5 s apart, 4 rotating queries. **DuckDuckGo:** 15 × HTTP 200 (median 615 ms, 28–30 KB, 10 results) and 5 × HTTP 202 "bots use DuckDuckGo too" image challenge (median 78 ms). In this run the 202s all fell on one query: "how do vaccines work" got 202 in all 5 of its rounds, and the other three queries got 200 in all 15 of theirs. A later check with `curl`, 6 s apart, sending the Safari `User-Agent`, `Accept`, `Accept-Language`, `Origin` and `Referer` but no `Sec-Fetch-*` or `Priority`, over curl's own TLS stack, got 200 for "how do vaccines work" and "vaccines", and 202 for "how vaccines work" and "how do airplanes fly". Its four results were written down afterwards in the scratch folder's `out/ddg-followup-6s.txt`, not in the run log. Because that check used different headers and TLS, it says little about URLSession; the 202s may follow the query, and their rate is uncertain. **Mojeek:** the first request already got a JavaScript captcha (curl got one too); 7 captchas, then HTTP 403 for the rest. Afterwards a real browser on the same network also got 403, "your network appears to be sending automated queries". **Startpage:** the homepage returned 200 with an `sc` token all 20 times, but all 20 searches returned an Anubis proof-of-work challenge page (`<script id="anubis_challenge">`, HTTP 200, no results). A real browser on the same network passed the challenge and got results. | For the owner: (a) **Mojeek:** blocked on this network, possibly because of the network's reputation or this probe. Rerun from another network (for example home) before deciding whether to keep it as a primary or drop it. (b) **Startpage:** challenged on every search with Safari headers. Drop it as backup, or take the spec's last resort, a `WKWebView` with JavaScript on that runs Startpage's challenge. That would be bot-check circumvention, like (c)'s header changes, and conflicts with spec §7's no-scripts stance and the sites' terms. (c) **DuckDuckGo:** some searches get the 202 check: one query type every time, or about 1 in 4 at random. Accept it with spec §2's backoff: DuckDuckGo then sits out 1–60 minutes, which leaves Wikipedia alone if (a) and (b) fall away. Or try the brief's "adjust the headers" fallback. The spike didn't vary headers through URLSession: deliberately retrying with changed headers to get past a bot check was refused as bot-check circumvention, and it's the owner's call. Note, though, that the `curl` follow-up above used different headers and TLS, and resent the challenged query "how do vaccines work", which then got 200; weigh that as you see fit. (d) **Region probably ignored:** the probe sent ddgs's `l=us-en`, but every DuckDuckGo results page came back with `<input name="kl" value="wt-wt">` (All regions) and no region selected. ddgs's predecessor, `duckduckgo_search` v8.0.0, sent `kl=<region>` to this same endpoint. So `l` is likely ignored and every search runs unlocalized; this is unverified live. Sending `kl` departs from the verbatim port and spec §2, so it's the owner's call; CP2's live check can confirm it by sending `kl` and looking for the echoed value. (e) **Headers differ from CP2's plan:** the probe's POSTs sent `Sec-Fetch-Site: same-origin`, `Origin`, `Referer` and `Priority: u=0, i`; CP2's `SafariHeaders.standard` sends `Sec-Fetch-Site: none`, no `Origin` or `Priority`, and `Referer` only to Startpage. The DuckDuckGo acceptance above was measured with the probe's set, so it may not carry over. The owner chooses which set CP2 sends. |
| Q5 | Are DuckDuckGo's links direct or `uddg=` wrapped? | **Direct.** | 15 result pages: 0 `uddg=` links, 0 `duckduckgo.com/y.js` ads, 0 `result--ad` items. Hrefs are direct http(s) URLs; the Japanese page includes one plain `http://` link. | Keep the `y.js` and `result--ad` filters and the `uddg=` unwrap as cheap insurance, as spec §2 says. No real ad page was captured, so tests need a hand-built ad fixture. |
| Q6 | Startpage token flow, reuse and latency | **The token flow works; the search behind it doesn't** (Q4). Reuse can't be measured. | `sc` found by the spec's XPath on 20/20 homepages, median 105 ms. Token plus search, to the challenge page: median 172 ms. The 30-second reuse test wasn't run, because every search was challenged. | Depends on the owner's Startpage decision in Q4. If Startpage stays, measure reuse and real latency then. |
| Q7 | MapKit fields, geocoding and terms | **The API works; the terms don't allow text without a map.** **Owner decision needed.** | `MKLocalSearch` "coffee", 5 km around 41.88, -87.63: 25 items in 497 ms. Filled in: `name`, `pointOfInterestCategory`, `addressRepresentations`, `address`, `timeZone`, `url` on 25/25; `phoneNumber` on 24/25. No public opening-hours property (only private ones such as `businessHours`; the macOS 27 SDK header has none). `MKGeocodingRequest(addressString: "Paris")` (macOS 26.0+): 1 item in 97 ms, 48.857, 2.351, "Paris, France". **Terms:** Apple Developer Program License Agreement, Attachment 6 "Use of the Apple Maps Service", §2.4: "You may not surface Map Data … without displaying the corresponding Apple map", <https://developer.apple.com/support/terms/apple-developer-program-license-agreement/#A6>. In the same attachment, §2.3 has the developer agree "not to copy, modify, translate, create a derivative work of … the Map Data", §2.2 bars use "as part of any secondary or derived database", and §2.5 limits caching and storage. Spec §6 hands places excerpts to the selected model. On the Cloud and Auto routes that means sending Map Data to a third-party provider, which rewrites it into an answer. | For the owner: spec §6's text excerpt for places, and geocoding a named place for weather, both surface Map Data without a map. Options: show an Apple map with places answers (`MKMapView` or `MKMapSnapshotter`); ask Apple; or drop MapKit for places (web results alone) and find another geocoder for weather, for example Open-Meteo's own geocoding API (same provider, no key, same non-commercial terms; it doesn't reverse-geocode). A map alone may not settle §2.2, §2.3 or the cloud-route transfer: weigh those too. The decision also covers today's `LocationService` (`Enigma/Search/LocationService.swift`), which reverse-geocodes the rounded location with `MKReverseGeocodingRequest` into `cityWithContext`. F29 sends that city to search sites ("near me" becomes "near <City>") and CP6 puts it in the weather excerpt, so dropping MapKit for places and weather alone still leaves the city coming from MapKit. CP6 waits on this. Fields for CP6 if MapKit stays: use `addressRepresentations.fullAddress(includingRegion: false, singleLine: true)` and `cityWithContext`; hours only from web pages. |
| Q8 | Open-Meteo shape and latency | **Works as specified.** | 5 requests, all HTTP 200: 119, 423, 122, 121, 122 ms, 6.6 KB. Every requested `current`, `hourly` and `daily` field present; `hourly` has 168 entries starting at local midnight today, not now, and `daily` has 7. Units: `°F`, `mp/h`, `inch`, `%`, `wmo code`. Times are ISO 8601 without an offset (`2026-10-27T15:30`), with `utc_offset_seconds` (-18000) and `timezone` alongside. The fixture spans the US daylight-saving change (1 November 2026), yet the hourly array is 168 steps of exactly one hour with no repeated 01:00 on 1 November, and sunrise moves only from 07:21 (31 October) to 07:23 (1 November): every date-time uses the single current offset, not wall-clock time in `timezone`. `daily.time` values are plain dates (`2026-11-02`). The response gives the grid point (41.8795, -87.6497), not the requested coordinate. | Parse `current.time`, `hourly.time`, `sunrise` and `sunset` with `utc_offset_seconds`, not `TimeZone(identifier: timezone)`; then format those instants in `TimeZone(identifier: timezone)` for display, so times after a daylight-saving change show true local time. Keep `daily.time` as calendar dates: shifting them by the offset and showing them in `timezone` labels every day after the change with the previous day's date. Pick "next 24 hours" from the hourly array by comparing with now. Saved as `open-meteo-chicago.json`. |
| Q9 | `NLTagger` lemma languages | **English only.** French, German, Spanish, Italian, Portuguese and Japanese return no lemmas, offline or online. | Run with the network denied (`sandbox-exec`, confirmed blocked): English 11/11 ("children→child", "prices→price", "cheaper→cheap"); the other six 0/10–0/14, and `availableTagSchemes(for: .word, language:)` doesn't include `.lemma` for them. Same result with the network on. `NLTagger.requestAssets` wasn't tried. | Lemmatize English only. Every other language uses lowercased words (spec §5's fallback), which makes the Wikipedia lane, BM25 and the off-topic check weaker for them. CP5 could try `requestAssets` or Snowball-style stemming later; no change now. |

1. **Summary:** Ran throwaway probes for all nine open questions, in a
   scratch folder outside the repository. The parser, the sealed WebKit
   view, Readability, Open-Meteo and English lemmas work as the spec
   assumes; parsing is confirmed for DuckDuckGo only (Q1). Three findings need the owner before CP2 and CP6: Mojeek and
   Startpage refuse URLSession searches on this network, and DuckDuckGo
   challenged 5 of 20 and probably ignores the region, and the header set
   CP2 sends needs choosing (Q4, Q6); keeping
   Startpage probably needs a parser dependency (Q1); Apple's terms forbid
   showing MapKit results as text without an Apple map (Q7). Lemmas exist
   only for English (Q9).
2. **Files:**
   - `EnigmaTests/Fixtures/Search/*.html`, `open-meteo-chicago.json`: the
     captured pages (task 0.1) and forecast (task 0.5), sanitized.
   - `EnigmaTests/Fixtures/Search/README.md`: one line per fixture.
   - This brief's Hand-off, and the CP0 row of the plan's progress log.
   - No project, source or test-code changes. Fixtures aren't registered in
     the Xcode project, as the workflow says.
3. **Decisions:**
   - Fixture names differ from the brief where the brief's page doesn't
     exist. DuckDuckGo returned 10 fuzzy results for "qzxv flarbnok 9183",
     so that file is `duckduckgo-nonsense-query.html`, not
     `duckduckgo-no-results.html`. There is no `mojeek-results.html`,
     `mojeek-no-results.html`, `startpage-results.html` or
     `startpage-no-results.html`: those sites only returned block pages,
     saved as `mojeek-captcha.html`, `mojeek-forbidden.html` and
     `startpage-challenge.html`. Added `duckduckgo-results-japanese.html`
     for the encoding test.
   - The `vqd` and `sc` session tokens, and the IP address in Startpage's
     challenge, were replaced with `REDACTED`. On Startpage's homepage, every
     copy of the `sc` token (inputs, links, scripts), the `session_id`,
     `bds_session_id`, `feedback_token`, `impressionToken`, `thash` and
     `page_id` values were replaced too, `request_time` was set to `0`, and
     the geo-IP point Startpage embeds for the network (`"req_loc"`) was set
     to `0`, `0`. Mojeek's captcha feedback `data-id`, and DuckDuckGo's
     block-page `o=` value, `r=` region code, `gk=` value and support code,
     were replaced as well. Startpage's country code (`US`) stays: it is
     country-level and matches the region the request sent. The `sc` inputs stay non-empty, so
     the token XPath still has something to find. Startpage's
     one-time challenge `id` and `randomData`, and DuckDuckGo's challenge
     image codes, remain; they aren't personal data.
   - The probe's Safari headers were `User-Agent` (Safari 27.0.1, read from
     the installed bundle), `Accept`, `Accept-Language: en-US,en;q=0.9`,
     `Sec-Fetch-Site/Mode/Dest`, `Priority: u=0, i`, and `Origin` plus
     `Referer` on the POSTs. No header variations through URLSession; the
     `curl` follow-up in Q4 used different headers and TLS, and resent the
     challenged query.
   - The news article for Readability was a BBC News page, kept in the
     scratch folder only.
4. **Verification:** no app code changed, so no build or test run. The
   probes live in a scratch folder outside the repository (`<probes>` below),
   with their output in `<out>`:
   - `swift <probes>/sites.swift <out>/empty empty` (nonsense query) and
     `swift <probes>/sites.swift <out>/run run` (20 rounds): see Q4–Q6.
   - `swift <probes>/parse.swift ddg <pages…>`, then the same with `mojeek`
     and `startpage` on the sanitized fixtures, and
     `swift <probes>/sc.swift startpage-home.html`: see Q1.
   - `swift <probes>/webkit.swift <readability-0.6.0-dir> <article.html>`:
     see Q2 and Q3.
   - `swift <probes>/mapkit.swift`: see Q7.
   - `curl` of spec §6's Open-Meteo URL for 41.88, -87.63 with US units,
     5 times, 1 s apart: see Q8.
   - `sandbox-exec -p '(version 1)(allow default)(deny network*)' swift <probes>/lemma.swift`
     (its first line confirmed the network was blocked; round 2 found that
     check unreliable because `URLSession.shared` can answer from cache,
     reran it with an ephemeral session and a unique URL, which was blocked,
     and got the same lemma results), then
     `swift <probes>/lemma.swift`: see Q9.
   - Fixtures checked for the IP address, the city, numeric coordinates,
     session values, account names and the username after redaction. Round 2
     found the network's geo-IP point still in `startpage-home.html`; it is
     now `0`, `0`. Round 3 found per-request identifiers in three fixtures;
     they are redacted. The only locations left are the deliberate Chicago test
     location in the Open-Meteo file and Tokyo, the subject of the Japanese
     query. Every other decimal pair is SVG path data.
   - Review: round 1 (Opus, xhigh) found no Blockers, 5 Should fixes and
     7 Nits. Round 2 found 1 Blocker (the geo-IP point above), 5 Should
     fixes and 7 Nits. Round 3 found no Blockers, 3 Should fixes and
     6 Nits. Round 4, the last allowed, found no Blockers, 4 Should fixes
     and 4 Nits (a stable `gk=` value on DuckDuckGo's block page, date-only
     `daily.time` values, a missing owner decision in the Summary, and a
     contradiction about header variations). All are fixed in this
     Hand-off, the fixtures and their README; the round-4 fixes weren't
     reviewed again. Every reviewer reran the parsing and WebKit probes.
5. **Limitations:**
   - One network, one afternoon. The Mojeek block and DuckDuckGo's 202 rate
     may be specific to this network, and the probe itself may have caused
     Mojeek's network-wide block. Rerun the acceptance check from another
     network before deciding Q4.
   - The Mac runs macOS 27.0.1, not 26; the WebKit, MapKit and lemma
     answers aren't confirmed on 26.
   - Q6's token reuse and latency with real results are unmeasured.
   - The Readability check used one article.
   - Parsing of real Mojeek and Startpage results pages with `XMLDocument`
     is untested (Q1).
6. **For the next checkpoint:**
   - Parse search pages with `XMLDocument(xmlString:options: [.documentTidyHTML])`
     after decoding; `data:` breaks every non-ASCII character. Tidy
     restructures HTML5 markup (Q1), so check each site's XPaths against a
     captured page.
   - Join text as ddgs does: concatenate the text nodes with no separator,
     then collapse whitespace (`" ".join("".join(nodes).split())`). From
     ddgs's `_normalize_text` (`ddgs/utils.py` at `8e749591`), port only NFC
     normalization and removing Unicode "C" category characters (format
     characters such as zero-width spaces included). Don't port its tag
     stripping: it runs after entities are unescaped, so "AsyncStream<Element>"
     becomes "AsyncStream". Don't port `_normalize_url` either
     (`unquote(url).replace(" ", "+")`): it turns `/My%20File.pdf` into
     `/My+File.pdf` and `?q=a%26b%23c` into `?q=a&b#c`. Keep hrefs as
     returned, unwrapping only `uddg=`.
   - Block markers in the fixtures:
     - DuckDuckGo: `id="challenge-form"`, `anomaly-modal__` classes and the
       text "bots use DuckDuckGo too" (about 14 KB, no result items).
       `duckduckgo-blocked.html` was served with HTTP 202, which CP2 maps to
       `.rateLimited`; the markers mean `.blocked` under any other status.
     - Mojeek: `<title>Captcha` (HTTP 200), and HTTP 403. The 403 page
       echoes the query (334–345 bytes), so don't use its size as a marker.
     - Startpage: `<script id="anubis_challenge">` (HTTP 200).
   - Until the owner decides Q4, CP2's live Mojeek and Startpage checks, and
     its Mojeek and Startpage results and no-results tests, have no page to
     pass against.
   - Expected values for `testDuckDuckGoParsesResults` are in the fixtures
     README.
   - DuckDuckGo matched results to the nonsense query, so a real "no
     results" marker is still unknown; CP2 needs one before it can tell an
     empty search from a layout change. A lead, unverified live:
     `duckduckgo_search` v8.0.0 checked for `No  results.` (two spaces) on
     this endpoint.
   - Open-Meteo date-times have no offset: apply `utc_offset_seconds` to
     them, but keep `daily.time` as plain dates (Q8). CP6's test should
     check a daily label after 1 November, not only the count.
