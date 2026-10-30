# Search fixtures

Captured on 2026-10-27 by the F29 CP0 spike, except where the table says
otherwise. The search pages came from an ephemeral `URLSession` sending
Safari 27.0.1 headers and ddgs's region field `l=us-en` (DuckDuckGo still
served `kl=wt-wt`, All regions), with no redirects followed; the Open-Meteo
files came from `curl`.
Tests read these files through `#filePath`. They contain no personal data:
the network's public IP address, the `vqd` and `sc` session tokens and
Startpage's session values were replaced with `REDACTED`, and the geo-IP
point Startpage embeds for the network was set to `0`, `0`. Per-request
identifiers were redacted too; the table lists each one. What remains on
purpose: Startpage's one-time challenge `id` and `randomData`; DuckDuckGo's
challenge image codes (`p=`), public asset names that were the same on every
block page; and Startpage's country code (`US`), country-level only and the
same as the `us-en` region the request sent.

| File | Source | Query | Redacted |
| --- | --- | --- | --- |
| `duckduckgo-results.html` | `POST https://html.duckduckgo.com/html/` (HTTP 200) | swift concurrency actors | `vqd` token value |
| `duckduckgo-results-japanese.html` | `POST https://html.duckduckgo.com/html/` (HTTP 200) | 東京 天気 | `vqd` token value |
| `duckduckgo-nonsense-query.html` | `POST https://html.duckduckgo.com/html/` (HTTP 200). DuckDuckGo returned 10 fuzzy results, not a no-results page | qzxv flarbnok 9183 | nothing found |
| `duckduckgo-blocked.html` | `POST https://html.duckduckgo.com/html/` (HTTP 202, "bots use DuckDuckGo too" image challenge) | how do vaccines work | `o=` request value, `r=` region code and `gk=` value in the challenge-form actions, tracking pixel and Submit button; the support code (`Code:` and the `error-lite+…@` address) |
| `mojeek-captcha.html` | `GET https://www.mojeek.com/search?q=` (HTTP 200, page titled "Captcha", JavaScript challenge) | swift concurrency actors | the Feedback link's `data-id` |
| `mojeek-forbidden.html` | `GET https://www.mojeek.com/search?q=` (HTTP 403, "your network appears to be sending automated queries") | 東京 天気 | nothing found |
| `startpage-home.html` | `GET https://www.startpage.com/` (HTTP 200), holding the `sc` input | — | every copy of the `sc` token (four inputs, two links, three script values), `session_id`, `bds_session_id`, `feedback_token`, `impressionToken`, `thash`, `page_id`; `request_time` and the `req_loc` coordinates set to `0` |
| `startpage-challenge.html` | `POST https://www.startpage.com/sp/search` (HTTP 200, JavaScript proof-of-work challenge, no results) | swift concurrency actors | `X-Real-Ip` address |
| `open-meteo-chicago.json` | `GET https://api.open-meteo.com/v1/forecast` for 41.88, -87.63 with US units, spec §6's fields | — | nothing found (Chicago is the fixed test location, not the user's) |
| `open-meteo-geocoding-paris.json` | `GET https://geocoding-api.open-meteo.com/v1/search?name=Paris&count=1&language=en&format=json` (HTTP 200), captured 2026-10-29 by F29 CP0b with `curl` | — | nothing found (a public place record; no request data is echoed) |
| `duckduckgo-no-results.html` | `POST https://html.duckduckgo.com/html/` (HTTP 200) with header set A and `kl=us-en`, captured 2026-10-30 by F29 CP2: one `result--no-result` item holding the `no-results` message, no link | "zqxjvbw ploqmzrtk yhvndkwq fjzxqpl" (quoted) | nothing found (the page has no `vqd` token) |
| `duckduckgo-changed.html` | Made by CP2 from `duckduckgo-results.html`, with `body` renamed to `main` in every class, standing in for a layout change | swift concurrency actors | as `duckduckgo-results.html` |
| `duckduckgo-ads.html` | Synthetic (CP2), in DuckDuckGo's result markup: two `result--ad` items (one `y.js` link, one direct), three organic results (one `uddg=` wrapped), one `javascript:` link | — | — |
| `wikipedia-search.json`, `wikipedia-extract.json` | Synthetic (CP2), in the shape of the MediaWiki API's `list=search` and `prop=extracts` JSON (`format=json`), about a made-up article | — | — |
| `wikidata-search.json` | `GET https://www.wikidata.org/w/api.php?action=wbsearchentities` (HTTP 200), captured 2026-10-30 by F29 CP7 with `curl` and trimmed to its first hit | Rust | nothing found (no request data beyond the entity name is echoed) |
| `wikidata-entity-rust.json`, `wikidata-entity-nobel.json`, `wikidata-entity-everest.json` | `GET …?action=wbgetentities&props=labels\|descriptions\|claims&languages=en` for Q575650, Q37922 and Q513 (HTTP 200), captured 2026-10-30 by F29 CP7 and trimmed to a few statements of P348/P571, P1346/P571 and P2044 (statement IDs, references and other qualifiers dropped) | — | `pageid`, `lastrevid`, `modified` and statement IDs dropped while trimming |
| `wikidata-labels.json` | `GET …?action=wbgetentities&props=labels&languages=en` for the items those statements name (HTTP 200), captured 2026-10-30 by F29 CP7 | — | nothing found |
| `google-news.xml` | `GET https://news.google.com/rss/search?q=…&hl=en-US&gl=US&ceid=US:en` (HTTP 200, no cookie set), captured 2026-10-30 by F29 CP7 with `curl` and cut to 4 items | nobel prize literature | each item's article token (in `link`, `guid` and `description`) replaced with `CBMiFIXTURE<n>`; the feed's `lastBuildDate` kept |

## Expected values

`duckduckgo-results.html`, parsed with ddgs's XPaths after decoding as UTF-8:
10 items, none removed as ads. The first:

- title: `Concurrency - Documentation`
- URL: `https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/`
- snippet starts: `You use actors and isolation to protect against data races, as described in this chapter.`

`duckduckgo-results-japanese.html`: 10 items; the first title is
`東京の天気予報(1時間・今日明日・週間) - ウェザーニュース`, its URL
`https://weathernews.jp/onebox/tenki/tokyo/13100/`.

`duckduckgo-ads.html` gives 3 results: `https://organic.example/a`,
`https://example.com/a` (unwrapped) and `https://second.example/b`.

Block pages give 0 items. Their markers: `id="challenge-form"` and "bots use
DuckDuckGo too" (DuckDuckGo; this copy was served with HTTP 202); `<title>Captcha` (Mojeek, HTTP 200);
`<script id="anubis_challenge">` (Startpage, HTTP 200).
| `articles/` | Written for F29 CP4, original text only (see `articles/README.md`) | — | nothing to redact |
