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

## Expected values

`duckduckgo-results.html`, parsed with ddgs's XPaths after decoding as UTF-8:
10 items, none removed as ads. The first:

- title: `Concurrency - Documentation`
- URL: `https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/`
- snippet starts: `You use actors and isolation to protect against data races, as described in this chapter.`

`duckduckgo-results-japanese.html`: 10 items; the first title is
`東京の天気予報(1時間・今日明日・週間) - ウェザーニュース`, its URL
`https://weathernews.jp/onebox/tenki/tokyo/13100/`.

Block pages give 0 items. Their markers: `id="challenge-form"` and "bots use
DuckDuckGo too" (DuckDuckGo; this copy was served with HTTP 202); `<title>Captcha` (Mojeek, HTTP 200);
`<script id="anubis_challenge">` (Startpage, HTTP 200).
