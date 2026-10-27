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

| # | Question | Answer | Evidence | Decision for later checkpoints |
| --- | --- | --- | --- | --- |
| Q1 | Does `XMLDocument` match ddgs's XPaths? | | | |
| Q2 | Do Enigma's scripts run with page JavaScript off? | | | |
| Q3 | Does the block-all rule stop every load? | | | |
| Q4 | Do the sites accept URLSession with Safari headers? | | | |
| Q5 | Are DuckDuckGo's links direct or `uddg=` wrapped? | | | |
| Q6 | Startpage token flow, reuse and latency | | | |
| Q7 | MapKit fields, geocoding and terms | | | |
| Q8 | Open-Meteo shape and latency | | | |
| Q9 | `NLTagger` lemma languages | | | |

1. **Summary:**
2. **Files:**
3. **Decisions:**
4. **Verification:**
5. **Limitations:**
6. **For the next checkpoint:**
