# Web Search

Enigma can ground answers in current web results, nearby places and the weather.
Search runs on this Mac with no account or key: Enigma asks DuckDuckGo and
Wikipedia, reads the result pages itself, and hands the best passages to your
selected model, local or cloud, which writes the answer and lists the sources it
was given. Places come from Apple Maps and the weather from Open-Meteo.
Questions that need fresh information search automatically, **/search** forces a
search for one message, and **/maps** finds places. Models that choose their own
tools decide for themselves when to search, look up places or check the weather;
see [On models that choose their own tools](#on-models-that-choose-their-own-tools).
On ChatGPT and Claude Code those models search the web with their provider's own
search instead; see [Cloud models' own search](#cloud-models-own-search).

## Set up

None. Search works from the first launch, in Local, Cloud and Auto.

**Brave Search, optional.** If you have a Brave Search API key with **LLM
Context** access, you can paste it into **Settings → Cloud and search → Web
search → Use Brave Search instead** and choose **Save key**. While a key is
saved, web searches go to Brave instead of running on this Mac, and the status
row reads **Brave in use**; places and weather still use Apple Maps and
Open-Meteo. Brave bills its usage separately, and the key is stored in the macOS
Keychain. **Remove key** goes back to on-device search from the next search.

![Web search in Settings → Cloud and search](design/ui-revamp/screenshots/phase-5/settings-cloud-full-paper.png)

## Automatic search

**Search automatically when fresh information is needed** is on by default. Turn
it off for manual-only search; the choice is remembered and applies in Local,
Cloud and Auto.

On models without native tools, Enigma decides on this Mac, from the wording of
the current question alone, with no extra model call. Questions like these
search:

- News and recent developments: "latest AI news", "what's happening in …"
- Facts that change: who holds an office, weather and forecasts, stock and
  crypto prices, exchange or mortgage rates, scores, opening times and schedules
- Nearby places and local weather without a named place: "cafes near me",
  "weather today" (see [Location](#location))
- Questions with words like "latest", "today", "this week" or "this weekend"
  ("whats" without an apostrophe counts as "what's"), and questions
  about this year's elections, releases or events
- Explicit requests such as "look up … online"

These don't search automatically:

- Text in quotes, backticks or code blocks
- Rewriting, translating, summarizing "this", writing code, and other tasks on
  text you supply
- Questions about your own work, such as "the current file" or "my latest draft"
- Historical questions, and requests such as "don't search" or "stay offline"
- File Mode and Messages requests, typed or recognized
- Questions about this chat, such as "the first message I sent you"
- Questions about your own communications, even when Messages isn't
  recognized. Texts, text messages, iMessages, SMS, voicemails, DMs and missed
  calls almost always mean your own, so any "my", "me", "I" or "our" anywhere
  in the message is enough: "who's been blowing up my phone with texts
  today". This can also hold back a public question such as "what are the latest
  SMS rules for my store"; type `/search` for those. Messages, emails, chats and calls
  have public meanings too, so they need "my", "me", a relative or "did I get"
  right next to them: "what are the most recent messages from my dad", "what
  emails came in today", "what did Mom say today", or a call with family such
  as "what did Grandpa say on the phone yesterday". News about others still
  searches, such as "the latest message from the White House on tariffs" or
  "when is the next earnings call for my stock", and so does a draft that
  can't tell, such as "what's the latest from Sam". A typed `/search` always
  searches.

Each message is decided on its own. Searching one question doesn't make the next
one search.

### The search chip

When a draft would search automatically, a `search` chip appears in the
composer bar while you type, so you know before sending. Click the chip to send
that message without searching; it stays off while you keep editing, on every
route (Local, Cloud and Auto), and comes back for the next message or when you
clear the field. With automatic search off there's no chip.
A typed `/screen` or `/snapshot` shows no chip, so the request it sends after
its capture never searches automatically; type `/search` with it to search.
That request is answered without search, with one exception: in Auto with Cloud
set up, a message that asks for a web lookup ("search the web", "look this up",
"latest news", "current price" and similar) isn't sent. Enigma keeps the capture
and draft and says "Use /search in your message to look this up on the web."
See [How Auto decides](Cloud-Model-Selection.md#how-auto-decides).
The chip follows the automatic-search setting, not **Recognize commands from
your wording**. See [Slash commands](Slash-Commands.md#recognized-commands).

## Explicit search with /search

Type **/search** anywhere in a message to search for that message only, even
for a timeless question and even when automatic search is off. It's highlighted
in the draft and stays visible until the message is accepted; delete it before
sending to cancel. `/search` combines with other commands, such as
`/screen /search what is this error?`. It can't be combined with attached files
or `/messages`. It's always offered in suggestions, Help and the welcome tour.
See [Slash commands](Slash-Commands.md).

## Places and weather

**On models without native tools,** Enigma sorts each searched question on this
Mac into one of three routes, from its wording alone:

- **Weather** ("will it rain tomorrow", "weather in Lisbon this weekend"):
  Open-Meteo's forecast for your approximate location, or for the named place,
  which Open-Meteo's geocoder finds (an exact name preferred). No search site is
  asked. If the place can't be found or Open-Meteo fails, a web search for
  "weather ‹place›" runs instead. Questions such as "what is the temperature to
  bake salmon" aren't weather.
- **Places** ("cafes near me", "ramen in Soho"): Apple Maps and a web search run
  side by side, and the places list comes first. Apple Maps looks within 5 km,
  widening to 20 km when it finds fewer than 3 places, and returns at most 10,
  with their category, address, distance, phone and website. If Apple Maps
  fails or finds nothing, the web results answer alone. For example,
  `/search cafe near me` takes this route.
- **Web:** everything else.

**/maps** asks for places directly: type `/maps bookshops` to look up bookshops
near you, or name an area (`/maps ramen in Soho`). On small models it takes the
places route; on models that choose their own tools, the model must call
`find_places` first. `/maps` wins over `/search` in the same message, and can't
be combined with attached files, `/messages` or a screenshot. `/maps` with
nothing to look for keeps your draft. It's always offered in suggestions, Help
and the welcome tour.

**The map card.** A finished reply that used places shows a small map under it,
with a numbered pin for each place the reply names (every place when it names
none). Click a pin to open that place in Apple Maps, or **Open in Maps** for all
of them. Scrolling over the map scrolls the chat. A reply stopped after it has
text keeps its card. The card is for this session only: it isn't saved, so a
chat reopened from Recents has none.

The places and weather answers are listed among the sources as **Apple Maps**
and **Open-Meteo forecast**.

## On models that choose their own tools

Local models of about 9B and up, both mixture-of-experts models, and the cloud
models have a **native tools** flag (see
[Slash commands](Slash-Commands.md#models-that-choose-their-own-tools)). On
these, the rules above and the `search` chip don't run. Instead, while automatic
search is on, every message offers the model three tools, and the model decides
whether to call them and writes their arguments itself:

- `web_search`: a query a few words long. It can search more than once in a
  reply; the sources of every search are listed on it. On ChatGPT and Claude
  Code the provider's own search takes its place
  ([below](#cloud-models-own-search)).
- `find_places`: what to find, and optionally a named area; without one, it
  searches near you. It returns up to 10 places from Apple Maps.
- `get_weather`: optionally a named place; without one, your location. It
  returns the current weather, the next 24 hours and the next 7 days from
  Open-Meteo.

A model may look up places or the weather near you without your wording asking
for it; only your city, or a coordinate rounded to about 1 km, is used.

- Automatic search off: the tools are offered only when you type `/search` or
  `/maps`.
- `/search` typed: the model must search first. `/maps` typed: it must call
  `find_places` first.
- Files or a screenshot attached: today's File Mode and screen paths, without
  the tools.
- In Auto, a question that needs a lookup no longer stops with "Use /search…",
  since the model can search for itself.

Enigma doesn't rewrite the model's query. A "near me" query gets your city added
on this Mac before it goes to the search sites. Results are fitted to 2,048
tokens on local routes and 8,192 on cloud routes.

**After message text enters a chat** (a Messages read, a search hit, an allowed
preview, or an earlier `/messages` turn), each `web_search`, `find_places` and
`get_weather` call in that chat asks first. For a search: **Search the web for
“‹query›”?** *This chat includes text from your messages. It will be sent to
search sites.* (to Brave, while a Brave key is saved), with **Don't allow**,
**For this conversation** and **Always**. The card shows the exact query on one
line, and the search goes out exactly as the card showed it. Places and weather
calls ask with **Find ‹what› near you?** or **Find ‹what› in ‹area›?**, and
**Check the weather for ‹place›?** or **Check the weather for your area?**,
naming Apple Maps or Open-Meteo. The three share one permission: **For this
conversation** covers web searches, places lookups and weather checks for the
rest of that chat, and **Always** covers them in every chat. Don't allow tells
the model "The user declined." See [Messages](Messages.md#permission-cards).

## Cloud models' own search

On **ChatGPT (Codex)** and **Claude Code**, a model that chooses its own tools
searches with its provider's search tool in place of Enigma's `web_search`:
Codex's web search in `live` mode, and Claude Code's `WebSearch` (never
`WebFetch`, which would read pages from this Mac). The provider runs the
searches on its servers, reads the pages there, and may search several times
in a reply; its instructions ask it to search at most 5 times, which Enigma
can't enforce on these routes. The searches count toward your ChatGPT or Claude
plan. The same switch and `/search` apply as above. `find_places` and
`get_weather` are offered beside the provider's search and run on this Mac as
above.

**In chats with message text, after a card.** The provider writes and runs its
own queries on its servers, so no card can show each one. In a chat that holds
text from your messages (a Messages read, a search hit, an allowed preview, or
an earlier `/messages` turn, including one reopened from Recents), and on a
typed `/messages` turn, Enigma asks once before the request: **Let ‹provider›
search the web in this chat?** *This chat includes text from your messages.
‹provider›'s web search runs its own queries on ‹company›'s servers, and Enigma
can't check each one.*, with **Don't allow**, **For this conversation** and
**Always**. ‹provider› is ChatGPT or Claude Code; a grant covers that provider
only, and **Always** grants are listed, and removable, under **Settings →
General → Messages → Always allowed**. **Don't allow** sends the question with
no search at all, not even Enigma's. With a grant, a read in that reply goes
straight to the provider.

**The restart.** If the model reads a chat partway through a reply that has the
provider's search and you haven't allowed it yet, Enigma holds the chat's text
back before it reaches the provider, clears the reply, and asks the card
above. Allowed, the same question runs again with the provider's search;
declined, it runs again without search. The read's grant still applies, so the
chat isn't asked for twice. This happens at most once per reply, and Stop
during it ends the turn. See [Messages](Messages.md) and [Chat](Chat.md).

**Sources.** The reply's sources are the pages the answer links, in order; if
it links none, the results the provider found. Only safe `http`/`https` links
are kept, without duplicates, at most 8, with the site name when a page has no
title. They're shown and saved like Enigma's own, and the line under the reply
says **web search**.

**Blocked sites.** Your blocked sites ([below](#sources-and-citations)) go with
the request, most recent first, as an instruction to avoid them. The providers
are asked, but Enigma can't enforce it.

**Fallback.** If the provider's search isn't available (a plan, a workspace
policy that allows no search mode, or a model without it), the same question
runs with Enigma's `web_search`. Enigma remembers that for the provider and
model until it quits. An error after the reply has started is shown like any
other.

**Nearby questions.** For a question about places or weather near you, with
**Use location for nearby questions** on, Enigma first finds your area on this
Mac and asks: **Share your location with ‹provider›?** *‹provider›'s web search
will use ‹City, Region, Country› to find nearby results. Enigma never sends
your exact position.*, with **Don't allow**, **For this conversation** and
**Always**. ‹provider› is ChatGPT or Claude Code. With a grant, the city,
region, country and time zone go with that question (Codex's search location
setting; on Claude Code, a sentence in the instructions); coordinates never
do. A grant covers that provider only: allowing ChatGPT doesn't allow Claude
Code, or the OpenAI API. **Always** grants are listed, and removable, under
**Settings → General → Messages → Always allowed**. **Don't allow**, or
location off or unavailable, sends nothing, and the model asks which city you
mean.

**Privacy compared with Enigma's search:**

| | Enigma's `web_search` | Provider's search |
| --- | --- | --- |
| Who runs the searches | Enigma, from this Mac | The provider, from its servers |
| Who writes the queries | The model | The model |
| Who sees the queries | The search sites (Brave instead, while a key is saved) | The provider and its search backend |
| Who sees your IP address | The search sites and each result site Enigma reads | Only the provider, as for any cloud request |
| Location | Your city, for "near me" queries | City, region, country and time zone, only after you allow it for that provider; never coordinates |
| After message text enters the chat | Every query asks first | Asks once per chat (or Always) for that provider, then the provider runs its own queries |

Nothing new is saved except **Always** grants for location and for searching
after message text: the availability marks live in memory, and logs name the
provider and the event, never a query or a link.

**Elsewhere.** Gemini keeps Enigma's `web_search` (Google requires showing its
own search-suggestions chip with grounded answers). The OpenAI and Anthropic
API-key routes keep it too for now. Unflagged models, File Mode and screenshot
turns are unchanged.

## Sources and citations

While a search runs, the reply's activity line moves through **Preparing search
query…** (only when the query is written from attached text, below),
**Searching…**, **Reading sources…**, **Finding places…** and **Checking the
weather…**. When the answer is done, the line reads **Activity · N sources**;
open it to see **web sources**, each with its title, site, URL and **Included in
context**. Clicking a source opens it in your browser. The line under the reply
includes **web search**, or **brave search** when Brave answered (**web search**
once Enigma has restarted).

![A reply with its web sources open](design/ui-revamp/screenshots/phase-7/activity-sources-paper.png)

The model is told to treat the excerpts as untrusted data and to cite only the
supporting URLs it was given. Only sources that actually fit into the prompt
are shown. A listed source means the model was given that excerpt, not that
every claim in the answer was checked against it.

**Never use this site.** Right-click a web source (or use its accessibility
action) and choose **Never use ‹domain›**. The row shows `blocked` with **Undo**
until the panel closes. Later searches skip that domain and its subdomains,
whichever search runs (Brave's results are filtered on this Mac too), and the
reply already written doesn't change. Apple Maps and Open-Meteo sources can't be
blocked. A Google News headlines source links Google News itself, so blocking it
stops the headlines. Blocked sites, at most 500, are listed with **Remove** under
**Settings → Cloud and search → Web search → Blocked sites**.

If searching fails, Enigma doesn't quietly answer without evidence. It shows an
error and keeps your draft: search sites limiting requests, no connection, an
invalid response, no usable sources, nothing to search for, or not enough room
in the model's context for sources. With a saved Brave key, the messages name
Brave, and a rejected key says so. **Stop** cancels the search, the page reading
and the answer.

## Privacy

**What leaves the Mac:**

| Recipient | What | When |
| --- | --- | --- |
| DuckDuckGo | The query (commands removed, at most 50 words and 400 characters, your city for nearby questions), the region and language, Safari's user agent, your IP address | Every web search |
| Wikipedia | The query, Enigma's user agent, your IP address | Every web search (not for today or this-week questions) |
| Wikidata | The entity name the query rewrite wrote, or the title of the Wikipedia article the search found; Enigma's user agent; your IP address | Web searches about a named thing |
| Google News | The first keyword query, the language and region codes, Enigma's user agent, your IP address. No cookies and no location: a search that carries your city skips Google News. No article link is followed. Nothing once you've blocked Google News | News and recency questions |
| Result sites, up to 6 at a time; more when a read fails or the "enough?" check reads again | One GET each, over HTTPS, following up to 5 redirects, with no cookies, `Referer`, images, scripts or other subresources | Every web search |
| Open-Meteo | Coordinates rounded to about 1 km, or a named place to geocode | Weather questions |
| Apple (MapKit) | The place query and your approximate area or the named area; your coordinates rounded to about 1 km, to find your city; map tiles for the card's region | Places questions, and any nearby question |
| Brave, only while a key is saved | The query and, for nearby questions, your city only; your key; your IP address | Web searches only |
| The model's provider, on cloud routes | The excerpts, places list or forecast | Every search a cloud model makes |

- **The query.** Normally it's your current question, trimmed to 50 words and
  400 characters. Slash commands such as `/think`, `/edit` and `/translate` are
  removed on every route. If nothing is left and nothing is attached (for
  example `/search /translate` with no selection), nothing is sent: Enigma says
  there's nothing to search for and keeps your draft.
- **The query rewrite and the "enough?" check** (small models only;
  [How it works](#how-it-works)) run on this Mac with the chat's own local model.
  Only the keyword queries they write, and the entity name, leave the Mac.
- **Attached material.** With a screenshot, selected text or a proposed revision
  attached, your selected model first writes a short query from your question
  (without slash commands) and the relevant parts of that material. Screenshots
  and attached text use the same query-writing prompt, which treats the material
  as quoted data and tells the model to leave out unrelated content, credentials
  and personal details, but that isn't guaranteed. Pixels, full OCR text and the
  full selection are not sent. A message that is only commands, such as
  `/search /translate` with a selection, still searches, with a query written
  from the attached material alone. If the model can't write a usable query,
  Enigma says so, names the screen or the attached text, and keeps your draft.
- **Never sent:** conversation history, attached files, Messages content,
  model-provider credentials, precise coordinates, and whole selections or
  screenshots.
- **Compared with a keyed search service:** queries aren't tied to an account
  key, and coordinates don't go to a search site. More parties see your IP
  address: the search sites, and each result site Enigma reads, as if you had
  clicked the link.
- **Who can start a search:** on small models, only your current question,
  `/search` or `/maps`. Attached text, OCR, files and earlier messages can refine
  an approved query but can't cause a search on their own, and an automatic
  search always shows its chip before you send. On models that choose their own
  tools, the model decides and writes the query, and could be steered by text in
  the chat; once message text is in the chat, no search, places or weather call
  leaves without your answer on a card. One **For this conversation** answer
  covers all three kinds of call in that chat, and **Always** covers them in
  every chat; a provider's own search has one card for its searches in that
  chat.
- **Where the answer comes from:** search controls retrieval, not the model. In
  Local mode the answer is written on this Mac, but the queries still go to the
  recipients above.
- **What is saved:** the chat keeps your message, the answer and the source
  titles and links, never your location. The excerpts given to the model, the
  map card's places and site health are not saved. Search adds only the blocked
  sites (domains only) to preferences, beside the automatic-search switch and
  any **Always** grants. WebKit keeps a compiled copy of the one
  block-everything rule page reading uses. A saved Brave key is kept in the
  Keychain as its own item, separate from model-provider keys, never in
  preferences or chat history.
- **Logs:** Console entries (category `search`) carry a site's name, status and
  size, never a query or a URL.

### Location

**Settings → General → Location → Use location for nearby questions** is on by
default. It's used only for a nearby question without a named place: places and
weather near you. macOS asks for permission the first time. The area is used for
that question only, is not saved, and requests give up after 20 seconds. Search
sites get only your city; weather uses coordinates rounded to about 1 km, and
Apple Maps gets your approximate area. If location is off, denied or
unavailable, Enigma asks you to name a city and doesn't search; once you decline
in a chat, it stays declined for the rest of that chat. On ChatGPT and Claude
Code, the area reaches the provider's search only after you allow it on that
provider's card; see [Nearby questions](#cloud-models-own-search).

## How it works

A web search on this Mac goes through these steps:

1. **The queries.** On small models, a typed question is turned into keywords
   first: the chat's local model writes up to 3 keyword queries and an entity
   name (temperature 0, at most 64 tokens, within 2.5 seconds; each query 1–10
   words and at most 80 characters). If there's no local model, or it fails,
   times out or writes something unusable, a code-only clean-up drops question
   words, filler and punctuation and keeps names, numbers and words such as
   "latest". At most 2 queries go to DuckDuckGo; Wikipedia gets the first.
   Capable models' queries, queries written from attached material, and nearby
   questions are sent as written.
2. **The search sites.** DuckDuckGo's HTML results (the first page, in the
   Mac's region) and Wikipedia's full-text search (the first usable article among its top 3
   hits, in your preferred language's edition among the largest, otherwise
   English; not for today or this-week questions) run together. Each site waits at least 1 second between requests and gets 2
   seconds to answer. A site that blocks or rate-limits Enigma sits out for 1,
   5, 15, then 60 minutes while the others carry on. Beside them run Wikidata's
   facts (within 2.5 seconds) and, for news and recency questions, Google News
   headlines (within 2 seconds, up to 8, newest first).
3. **Ranking.** Results are cleaned of tracking parameters, merged across
   queries and sites, and scored by position. Blocked sites and sites on the
   bundled unsafe and spam lists are dropped. Trusted sources (government,
   universities, research and health bodies, official docs) count 1.3 times,
   sites Wikipedia's editors rate generally reliable 1.15 times, and generally
   unreliable sites and sites that can't be read half. Anything under 0.08 of
   the top score is dropped.
4. **Reading.** Up to 6 pages are read at a time, within 3 seconds of the
   results arriving, stopping once 5 pass the checks. Each page is fetched over
   HTTPS only (at most 3 MB and 5 redirects; addresses on your local network are
   refused), and Readability extracts its text in a sealed WebKit view with
   scripts, images and every other subresource blocked, within 0.8 seconds.
   Pages that are too short, walled, duplicates, in another language or off
   topic are dropped; stale pages count half for recency questions. When too
   few pages can be read, results' snippets stand in, up to 4 sources in all.
5. **Passages.** Each page is split into passages of about 180 words and scored
   against the question (BM25, with a bonus for query words close together).
6. **The "enough?" check** (small models only). The local model sees the
   question and up to 350 words of the best passages, and says whether they
   answer it (at most 24 tokens, within 2.5 seconds). If not, one more
   DuckDuckGo search runs with the missing words (at most 6), and its new pages
   are read within 1.5 seconds. Any failure or timeout means no retry.
7. **Fitting.** The facts come first, then the headlines, then the page
   passages: up to 8 sources, 2,048 tokens each and 8,192 in all, then fitted to
   the selected model's context.

The files:

- `Enigma/Search/WebSearchSettings.swift`: `WebSearchSettings` holds the
  automatic-search preference (`webSearch.automaticallySearch`, default on), the
  blocked sites (`webSearch.blockedSites`) and whether a Brave key is saved;
  `KeychainSearchCredentialStore` stores that key.
- `Enigma/Search/WebSearchSettingsSection.swift`: the **Web search** section of
  Settings: the switch, the status, the optional Brave key, blocked sites and
  the note.
- `Enigma/Search/WebSearchPolicy.swift`: `needsFreshInformation`, the
  deterministic automatic-search decision on the question with quoted material
  removed, and `recency`, the day, week, month or year hint.
- `Enigma/App/ComposerIntent.swift`: `ComposerIntent.resolve` runs the policy on
  the typed draft for the `search` chip, and drops it for dismissals, attached
  files and Messages requests.
- `Enigma/LocalInference/LocalChatViewModel.swift`: `shouldSearch` combines
  `/search`, `/maps` and the policy. The Local, Cloud, Auto and Screen paths call
  `search`, which removes slash commands, refines the query when text is
  attached, builds a `WebSearchRequest`, and picks Brave for web routes while a
  key is saved, on-device search otherwise. It also filters Brave's results by
  the blocked sites and collects the reply's places for the map card.
- `Enigma/Search/WebSearch.swift`: the shared types: `WebSearchProvider`,
  `WebSearchRequest`, `WebSearchResult`, `WebSearchSource`, `WebSearchError` and
  `WebSearchLimits` (8 sources, 2,048 tokens each, 8,192 in all).
- `Enigma/Search/SearchRouting.swift`: `SearchRouting.decide` picks weather,
  places or web from the typed question; `webQuery` turns "near me" into
  "near ‹city›".
- `Enigma/Search/OnDeviceSearch.swift`: `OnDeviceSearchProvider` runs the routes
  and the steps above; `OnDeviceSearchTiming` holds its numbers.
- `Enigma/Search/SearchAssist.swift`: the query rewrite, the code-only clean-up
  and the "enough?" check (`SearchAssistTuning`).
- `Enigma/Search/Engines/SearchEngine.swift` and `SearchSiteRunner.swift`: the
  site interface, pacing, health and cooldowns, and running the sites together.
- `Enigma/Search/Engines/DuckDuckGoEngine.swift` and `WikipediaSearch.swift`:
  the two search sites. DuckDuckGo's request and parsing are ported from ddgs,
  recorded in `Engines/UPSTREAM.json`.
- `Enigma/Search/Engines/WikidataFacts.swift`: dated facts about a named thing
  from Wikidata's API (a fixed list of properties, newest first).
- `Enigma/Search/Engines/GoogleNewsSearch.swift`: Google News RSS headlines, with
  their publisher and date.
- `Enigma/Search/SearchHTTPClient.swift`: the ephemeral, cookie-free HTTP client
  the sites share.
- `Enigma/Search/ResultRanking.swift` (`RankingTuning`) and `SourceQuality.swift`:
  link clean-up, scoring, the bundled lists and the page checks;
  `PublicSuffixList.swift` finds each link's site.
- `Enigma/Search/PageReader.swift`: downloads result pages and refuses local
  addresses. `ArticleExtractor.swift`: Readability in a sealed WebKit view.
- `Enigma/Search/PassageRanker.swift`: splits and scores passages.
- `Enigma/Search/PlaceSearch.swift` and `WeatherLookup.swift`: Apple Maps places,
  and Open-Meteo's forecast and geocoder.
- `Enigma/Search/PlacesAndWeatherTools.swift`: `find_places` and `get_weather`.
- `Enigma/Search/WebSearchTool.swift`: `web_search`. It turns the model's query
  into the card's one-line form, asks the card when the chat holds message text,
  then searches.
- `Enigma/Search/BraveSearchClient.swift`: the optional Brave client
  (`POST https://api.search.brave.com/res/v1/llm/context`, with the city only).
- `Enigma/Search/WebSearchContext.swift`: `WebSearchContext.prepare` fits the
  evidence into the selected model's context with the model's own token
  counting. The question is never cut.
- `Enigma/Search/LocationService.swift`: `LocationIntent` decides when a question
  is about nearby places; `LocationService` makes one bounded, cancellable
  location request.
- `Enigma/Screen/ScreenPromptContext.swift`: `ScreenSearchContext` holds the one
  query-writing prompt for screenshots and attached text, and checks the query
  it writes.
- `Enigma/Chat/AssistantActivity.swift` and `AssistantActivityView.swift`: the
  activity phases, the **web sources** list and **Never use this site**.
- `Enigma/Chat/MapCard.swift`: the map card, its pins and **Open in Maps**.
- `Enigma/Cloud/NativeWebSearch.swift`, `CodexSubscriptionClient.swift` and
  `ClaudeCodeSubscriptionClient.swift`: providers' own search (F30).
- `Enigma/Resources/SearchData/`: the bundled lists (unsafe and spam sites,
  authority, Wikipedia's Perennial sources, unreadable sites, the Public Suffix
  List), Readability, and `manifest.json` with each list's version and date.

## Limitations

- Automatic search recognizes English wording and clear signals only. It can
  miss paraphrases, and can't resolve follow-ups such as "and yesterday?" from
  earlier messages; use `/search` with a complete question.
- AI-written pages can't be reliably detected; the spam lists catch only known
  sites.
- PDFs aren't read.
- Pages that need scripts to show their text fall back to the search site's
  snippet.
- Answers depend on what DuckDuckGo returns, which varies from run to run. In
  the evaluation, on-device search was weaker than Brave on news, docs and
  reviews; a Brave key is the stronger option for those.
- On small models, the query rewrite and the "enough?" check each add up to
  2.5 seconds, and a second DuckDuckGo query about 1 second.
- Open-Meteo's free API is for non-commercial use.
- Apple Maps in MapKit gives no opening hours.
- Enigma reads the search sites' pages and Google News's feed as a person's
  browser would; their terms may not allow automated use, and a site can block
  it at any time.
- Screen questions that search need one extra model call to write the query.
- On models that choose their own tools, whether a question searches depends on
  the model; see [Local models](Local-Model-Selection.md#native-tools).
- The map card matches places by name, so in languages written without spaces
  between words it usually pins every place.
- With the provider's search, Enigma doesn't see the queries or the page text,
  only the results the provider reports and the links in the answer, and can't
  enforce blocked sites. Whether Codex's search uses the shared location, and
  how Claude Code's `WebSearch` uses the area named in its instructions, depends
  on the provider.

## Maintenance

- **The lists.** `scripts/update-search-lists.py` refreshes the bundled lists
  and `manifest.json`. Run it before each release; `scripts/release.sh` warns,
  and carries on, when the lists are more than 60 days old
  (`scripts/check-search-lists-age.py`). Nothing downloads lists at runtime.
- **The ddgs watch.** `.github/workflows/ddgs-watch.yml` runs every Monday and
  on demand. `scripts/check-ddgs-upstream.py` compares the files recorded in
  `Engines/UPSTREAM.json` with ddgs's latest release through GitHub's API (it
  never contacts a search site), and when one changed, the workflow opens or
  updates one issue labelled `ddgs-upstream`, linking the diff. Port the change,
  refresh the fixtures, and record the new tag and blobs in `UPSTREAM.json`.
  A later drift rewrites the open issue's title and body, which GitHub doesn't
  notify anyone about, so check the issue's history. GitHub turns scheduled
  workflows off after 60 days without activity in the repository; re-enable it
  from the Actions tab.
- **Warning sign.** A site's `unrecognized` outcome in Console (category
  `search`). Search keeps running on the other sites meanwhile.

## Tests

- `EnigmaTests/WebSearchTests.swift`: automatic-search examples and opt-outs,
  search with no setup, Brave only with a saved key and only for web searches,
  blocked sites filtering Brave, the error messages, query limits and command
  boundaries, query refinement, location handling, evidence fitting, failures
  that keep the draft, cancellation, and **Never use this site** with Undo.
- `OnDeviceSearchTests`: the pipeline end to end with fixtures: the routes,
  reading, the snippet fallback, timing and Stop.
- `SearchAssistTests`: the rewrite, the clean-up, the "enough?" check and its
  retry. `SearchFactsAndNewsTests`: Wikidata and Google News, blocking and
  cancellation.
- `SearchEngineTests`, `SearchSiteRunnerTests` and `SearchHTTPClientTests`: the
  sites' requests and parsing from saved pages, pacing, health and cooldowns.
- `SearchRankingTests`, `SourceQualityTests`, `PageReaderTests`,
  `ArticleExtractorTests` and `PassageRankerTests`: ranking, the lists, page
  checks, downloads and the local-address guard, extraction and passages.
- `SearchRoutingTests`, `PlacesAndWeatherTests` and `PlacesAndWeatherToolTests`:
  the three routes, Apple Maps and Open-Meteo, and the two tools.
- `MapCardTests`: the card's pins, opening Maps and the session-only places.
- `ComposerIntentTests`, `ComposerIntentPhrasingTests`, `ScreenViewTests`,
  `ScreenPipelineTests`, `NativeToolPartsTests`, `NativeToolPlanTests`,
  `NativeToolRequestTests` and `ToolPermissionTests`: the chip, `/maps`, the
  tools on capable models, and the cards after message text.
- `NativeWebSearchTests`, `CodexSubscriptionTests` and
  `ClaudeCodeSubscriptionTests`: providers' own search.
- `EnigmaSettingsTests`: the Settings section and blocked sites.

The tests use fixtures and need no key or network. The opt-in live checks
(`ENIGMA_LIVE_SEARCH`), the fixture refresh (`ENIGMA_SEARCH_FIXTURE_DIR`) and the
quality evaluation (`ENIGMA_SEARCH_EVAL`) are described in
[Testing](Testing.md). The scripts' tests run with
`python3 -I -B -m unittest discover -s scripts/tests`.

Run the search tests with
`scripts/verify-xcode.sh test -only-testing:EnigmaTests/WebSearchTests -only-testing:EnigmaTests/OnDeviceSearchTests`.
See [Testing](Testing.md).
