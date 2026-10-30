# Web Search

Enigma can ground answers in current web results from Brave Search. With your own
Brave Search API key saved, questions that need fresh information search
automatically, and **/search** forces a search for one message. Your selected
model, local or cloud, writes the answer and the reply lists the sources it was
given. Models that choose their own tools decide for themselves when to search,
and write their own query; see
[On models that choose their own tools](#on-models-that-choose-their-own-tools).
On ChatGPT and Claude Code those models search with their provider's own search
instead, with no Brave key; see [Cloud models' own search](#cloud-models-own-search).

## Set up

1. Get a Brave Search API key with **LLM Context** access from the Brave Search
   API dashboard. Brave bills its usage separately from any model provider.
2. Paste it into **Settings → Cloud and search → Web search · Brave** and choose
   **Save key** (or press **Return**). The welcome setup's **Connect what you use**
   step has the same field, under **Search**.
3. The status changes from **no key** to **key saved**. **Remove key** deletes it.

![Web search · Brave in Settings → Cloud and search](design/ui-revamp/screenshots/phase-5/settings-cloud-full-paper.png)

## Automatic search

**Search automatically when fresh information is needed** is on by default and
takes effect once a key is saved; on ChatGPT and Claude Code it also works
without one, through the provider's own search
([below](#cloud-models-own-search)). Turn it off for manual-only search; the
choice is remembered and applies in Local, Cloud and Auto.

On models without native tools, Enigma decides on this Mac, from the wording of
the current question alone, with no extra model call. Questions like these
search:

- News and recent developments: "latest AI news", "what's happening in …"
- Facts that change: who holds an office, weather and forecasts, stock and
  crypto prices, exchange or mortgage rates, scores, opening times and schedules
- Nearby places and local weather without a named place: "cafes near me",
  "weather today" (see Location below)
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
clear the field. With automatic search off, or without a key, there's no chip.
A typed `/screen` or `/snapshot` shows no chip, so the request it sends after
its capture never searches automatically; type `/search` with it to search.
That request is answered without search, with one exception: in Auto with Cloud
set up, a message that asks for a web lookup ("search the web", "look this up",
"latest news", "current price" and similar) isn't sent. Enigma keeps the capture
and draft and says "Use /search in your message to look this up with Brave."
See [How Auto decides](Cloud-Model-Selection.md#how-auto-decides).
The chip follows the automatic-search setting, not **Recognize commands from
your wording**. See [Slash commands](Slash-Commands.md#recognized-commands).

## Explicit search with /search

Type **/search** anywhere in a message to search for that message only, even
for a timeless question and even when automatic search is off. It's highlighted
in the draft and stays visible until the message is accepted; delete it before
sending to cancel. `/search` combines with other commands, such as
`/screen /search what is this error?`. It can't be combined with attached files
or `/messages`. See [Slash commands](Slash-Commands.md).

Without a saved key, `/search` isn't offered in suggestions, Help or the welcome
tour. If you type it anyway, Enigma reports that a key is needed and keeps your
draft, except on ChatGPT and Claude Code, where it asks the model to search with
its provider's own search.

## On models that choose their own tools

Local models of about 9B and up, both mixture-of-experts models, and the cloud
models have a **native tools** flag (see
[Slash commands](Slash-Commands.md#models-that-choose-their-own-tools)). On
these, the rules above and the `search` chip don't run. Instead, while automatic
search is on, every message offers the model a search tool, and the model
decides whether to search and writes the query itself, a few words long. It can
search more than once in a reply; the sources of every search are listed on it.
On ChatGPT and Claude Code the tool is the provider's own search, and no key is
needed ([below](#cloud-models-own-search)); everywhere else it's Enigma's
`web_search` on Brave, which needs a saved key.

- Automatic search off: the search tool is offered only when you type `/search`.
- `/search` typed: the model must search first.
- No key: `web_search` is never offered. On ChatGPT and Claude Code the
  provider's search still is (after a card once the chat holds message text,
  [below](#cloud-models-own-search)).
- Files or a screenshot attached: today's File Mode and screen paths, without
  `web_search`.
- In Auto, a question that needs a lookup no longer stops with "Use /search…",
  since the model can search for itself.

The query isn't refined by Enigma, since the model wrote it. A "near me" query
still gets the approximate area added on this Mac before it goes to Brave.
Results are fitted to 2,048 tokens on local routes and 8,192 on cloud routes.

**After message text enters a chat** (a Messages read, a search hit, an allowed
preview, or an earlier `/messages` turn), each web search in that chat asks
first: **Search the web for “‹query›”?** *This chat includes text from your
messages. It will be sent to Brave.*, with **Don't allow**, **For this
conversation** and **Always**. The card shows the exact query on one line, and
Brave gets exactly what the card showed. Don't allow tells the model "The user declined." See
[Messages](Messages.md#permission-cards).

## Cloud models' own search

On **ChatGPT (Codex)** and **Claude Code**, a model that chooses its own tools
searches with its provider's search tool in place of Enigma's `web_search`:
Codex's web search in `live` mode, and Claude Code's `WebSearch` (never
`WebFetch`, which would read pages from this Mac). The provider runs the
searches on its servers, reads the pages there, and may search several times
in a reply; its instructions ask it to search at most 5 times, which Enigma
can't enforce on these routes. No Brave key is needed; the searches count toward your
ChatGPT or Claude plan. The same switch and `/search` apply as above.

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
title. They're shown and saved as for Brave, and the line under the reply says
**web search** instead of **brave search**. Which search a reply used isn't
saved, so after Enigma restarts, any searched reply's line says **web search**.

**Fallback.** If the provider's search isn't available (a plan, a workspace
policy that allows no search mode, or a model without it), the same question
runs with Enigma's `web_search` when a key is saved, and without search
otherwise. Enigma remembers that for the provider and model until it quits. An
error after the reply has started is shown like any other.

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
| Who runs the searches | Enigma, from this Mac, on Brave | The provider, from its servers |
| Who writes the queries | The model | The model |
| Who sees the queries | Brave | The provider and its search backend |
| Who sees your IP address | Brave | Only the provider, as for any cloud request |
| Location | The approximate area, for "near me" queries | City, region, country and time zone, only after you allow it for that provider; never coordinates |
| After message text enters the chat | Every query asks first, naming Brave | Asks once per chat (or Always) for that provider, then the provider runs its own queries |

Nothing new is saved except **Always** grants for location and for searching
after message text: the availability
marks live in memory, and logs name the provider and the event, never a query
or a link.

**Elsewhere.** Gemini keeps Enigma's `web_search` (Google requires showing its
own search-suggestions chip with grounded answers). The OpenAI and Anthropic
API-key routes keep it too for now. Unflagged models, File Mode and screenshot
turns are unchanged.

## Sources and citations

While a search runs, the reply's activity line moves through **Preparing search
query…** (only when the query is refined, below), **Searching…** and
**Reading sources…**. When the answer is done, the line reads **Activity · N
sources**; open it to see **web sources**, each with its title, site, URL and
**Included in context**. Clicking a source opens it in your browser. The line
under the reply includes **brave search** (**web search** once Enigma has
restarted).

![A reply with its web sources open](design/ui-revamp/screenshots/phase-7/activity-sources-paper.png)

The model is told to treat the excerpts as untrusted data and to cite only the
supporting URLs it was given. Only sources that actually fit into the prompt
are shown; other results Brave returned are dropped. A listed source means the
model was given that excerpt, not that every claim in the answer was checked
against it.

If searching fails, Enigma doesn't quietly answer without evidence. It shows an
error and keeps your draft: a missing or rejected key, rate limiting, no
connection, an invalid response, no relevant sources, or not enough room in the
model's context for sources. **Stop** cancels both the search and the answer.

## Privacy

- **What goes to Brave:** a search query and your API key, over HTTPS, with
  nothing cached on disk and redirects refused.
  - Normally the query is your current question, trimmed to 50 words and 400
    characters. Slash commands such as `/think`, `/edit` and `/translate` are
    removed on every route. If nothing is left and nothing is attached (for
    example `/search /translate` with no selection), nothing is sent: Enigma
    says there's nothing to search for and keeps your draft.
  - With a screenshot, selected text or a proposed revision attached, your
    selected model first writes a short query from your question (without slash
    commands) and the relevant parts of that material. Screenshots and attached
    text use the same query-writing prompt, which treats the material as quoted
    data and tells the model to leave out unrelated content, credentials and
    personal details, but that isn't guaranteed. Pixels, full OCR text and the
    full selection are not sent. A message that is only commands, such as
    `/search /translate` with a selection, still searches, with a query written
    from the attached material alone. If the model can't write a usable query,
    Enigma says so, names the screen or the attached text, and keeps your draft.
  - For nearby questions, such as "weather today" or "cafes near me", an
    approximate area (city and coordinates rounded to about 1 km) is added. See
    Location below.
- **Never sent to Brave:** conversation history, attached files, Messages
  content, and model-provider credentials.
- **Who can trigger a search:** only your current question or `/search`.
  Attached text, OCR, files and earlier messages can refine an approved query
  but can't cause a search on their own. An automatic search always shows its
  chip before you send. On models that choose their own tools, the model
  decides and writes the query, and could be steered by text in the chat; once
  message text is in the chat, no query leaves without your click on a card
  (for a provider's own search, one card for its searches in that chat).
- **Where the answer comes from:** search controls retrieval, not the model. In
  Local mode the answer is written on this Mac, but the query still goes to
  Brave.
- **Key storage:** the key is kept in the macOS Keychain as its own item,
  separate from model-provider keys, and never in preferences or chat history.
- **What is saved:** the chat keeps your message, the answer and the source
  titles and links. The excerpts given to the model are not saved.

### Location

**Settings → General → Location → Use location for nearby questions** is on by
default. It's used only when a search runs for a nearby question without a named
place. macOS asks for permission the first time. The area is used for that
question only, is not saved, and requests give up after 20 seconds. If location
is off, denied or unavailable, Enigma asks you to name a city and doesn't search.
On ChatGPT and Claude Code, the area reaches the provider's search only after
you allow it on that provider's card; see
[Nearby questions](#cloud-models-own-search).

## How it works

- `Enigma/Search/WebSearchSettings.swift`: `WebSearchSettings` holds the
  automatic-search preference (`webSearch.automaticallySearch` in user defaults,
  default on) and whether a key exists. `KeychainSearchCredentialStore` stores
  the key.
- `Enigma/Search/WebSearchSettingsSection.swift`: the **Web search · Brave**
  section of Settings.
- `Enigma/Search/WebSearchPolicy.swift`: `WebSearchPolicy.needsFreshInformation`
  is the deterministic automatic-search decision, using fixed English patterns
  on the question with quoted material removed.
- `Enigma/App/ComposerIntent.swift`: `ComposerIntent.resolve` runs the policy on
  the typed draft for the `search` chip, and drops it for dismissals, attached
  files and Messages requests. The composer sends its result as the final
  decision. `Context.recognizingCommands(false)`, used for the request a typed
  capture sends, turns off recognized commands and automatic search.
- `Enigma/LocalInference/LocalChatViewModel.swift`: `shouldSearch` combines
  `/search` with the policy. With `allowsAutomaticSearch: false`, as the composer
  and Auto's chosen route pass, it keeps the decision it was given, so a
  dismissed chip stays off. The Local, Cloud, Auto and Screen submission paths
  call the private `search` method, which removes slash commands, refines the
  query when text is attached and adds location. The Screen path writes its
  refined query first.
- `Enigma/Search/BraveSearchClient.swift`: `BraveSearchClient` sends
  `POST https://api.search.brave.com/res/v1/llm/context` with the
  `X-Subscription-Token` header, a 30-second timeout and an ephemeral session.
  It asks for up to 10 URLs and 8,192 evidence tokens, at most 2,048 per URL,
  keeps generic, point-of-interest and map results with safe HTTP(S) links, and
  never shows raw error bodies.
- `Enigma/Search/WebSearchContext.swift`: `WebSearchContext.prepare` fits
  evidence into the selected model's context. After reserving output, system
  instructions, any image and the full question, about half the remaining input
  space goes to excerpts. Each source gets at most 2,048 tokens or a third of
  that space (half with two sources, all of it with one), measured with the
  model's own token counting; space a short source doesn't use goes to the
  others. The question is never cut, and older chat history only fills what's
  left.
- `Enigma/Screen/ScreenPromptContext.swift`: `ScreenSearchContext` removes slash
  commands from the user's question (`question`), holds the one query-writing
  prompt (`queryPrompt`; its `Material` is a screenshot's OCR or attached text,
  and the prompt mentions only that), and validates refined queries: one line,
  at most 50 words and 400 characters, and not empty or a bare reply such as
  "Yes" or "UNKNOWN". A query the model wrote is sent as written.
  `ScreenSearchError` names the source when no usable query comes back.
- `Enigma/Search/LocationService.swift`: `LocationIntent` decides when a question
  is about nearby places; `LocationService` makes one bounded, cancellable
  location request.
- `Enigma/Chat/AssistantActivity.swift` and `AssistantActivityView.swift`: the
  activity phases and the **web sources** list.
- `Enigma/Search/WebSearchTool.swift`: `web_search` for flagged routes. It turns
  the model's query into the card's one-line form, asks the search-after-messages
  card through `mayQuery` when the chat holds message text, then searches.
  `LocalChatViewModel.submitNative` builds it with `NativeToolPlan`'s parts.
- `Enigma/Cloud/NativeWebSearch.swift`: provider search (F30).
  `NativeWebSearch.isAllowed` decides it per turn; `ProviderSearchPart` is its
  instruction; `selectSources` and `NativeWebSearchSources` pick a reply's
  sources; `NativeWebSearchAvailability` remembers the fallback in memory;
  `ProviderSearchRestart` stops a request that message text would enter.
  `CloudProviderID.nativeWebSearchProviders` lists the routes it's on.
- `Enigma/Cloud/CodexSubscriptionClient.swift` and `CloudToolCalling.swift`
  (`CodexToolMode`): Codex's thread `web_search` setting, its workspace policy,
  `webSearch` items and the restart. `ClaudeCodeSubscriptionClient.swift` and
  `ClaudeCodeToolMode`: `--tools WebSearch`, the `init` check and search
  events. `submitNative` runs the location card, the provider-search card
  (`ToolPermission.providerSearchAfterMessages`), the fallback and the restart.

API reference: [Brave LLM Context](https://api-dashboard.search.brave.com/documentation/services/llm-context).

## Limitations

- Automatic search recognizes English wording and clear signals only. It can
  miss paraphrases, and can't resolve follow-ups such as "and yesterday?" from
  earlier messages; use `/search` with a complete question.
- Enigma doesn't check how recent or accurate each source is.
- Screen questions that search need one extra model call to write the query.
- Brave usage, limits and billing depend on your Brave plan.
- On models that choose their own tools, whether a question searches depends on
  the model. The tool-use eval measured it on the flagged models it covered; see
  [Local models](Local-Model-Selection.md#native-tools).
- With the provider's search, Enigma doesn't see the queries or the page text,
  only the results the provider reports and the links in the answer. The
  provider's search is its own: which sites it uses and how fresh they are
  aren't Enigma's to choose.
- Whether Codex's search uses the shared location for nearby results, and how
  Claude Code's `WebSearch` uses the area named in its instructions, depends on
  the provider.

## Tests

`EnigmaTests/WebSearchTests.swift` covers the Brave request and response format,
error handling without exposing response bodies, query limits and command
boundaries, saving and removing the key, automatic-search examples and opt-outs,
the setting and missing-key behavior in the real composers, attached text that
can't authorize a search, slash commands kept out of the query on every route,
query refinement and its privacy prompt, location handling, evidence fitting
and source selection across Local, Cloud, Auto and Screen, failures that keep the
draft, cancellation, older chats without source data, the rendered sources
list, and a decided search staying off on every route.
`EnigmaTests/ComposerIntentTests.swift` covers the `search` chip, its dismissal
and its conflicts, and no automatic search after a typed capture;
`EnigmaTests/ScreenViewTests.swift` checks that in the real composer, in Cloud
and Auto; `EnigmaTests/ScreenPipelineTests.swift` covers the screenshot query
writer, which never sees slash commands;
`EnigmaTests/ComposerIntentPhrasingTests.swift`, the phrasing corpus, checks
which drafts get the chip and that Messages drafts never do; and
`ComposerSubmissionTests` in `EnigmaTests/AppShellStateTests.swift` covers a
dismissed chip sending without search.
`EnigmaTests/NativeToolPartsTests.swift` covers `web_search`'s arguments, the
card's one-line query and a declined search;
`EnigmaTests/NativeToolRequestTests.swift` covers searching after an earlier
Messages turn, which asks, and a new chat, which doesn't. The tests use
fixtures and need no Brave key or network.
For the providers' own search, `EnigmaTests/NativeWebSearchTests.swift` covers
when it's allowed, source selection and the instruction;
`NativeToolPlanTests` and `NativeToolRequestTests` cover the plan's search
backend, the location card per provider, the provider-search card after
message text, the fallback and the restart;
`CodexSubscriptionTests` and `ClaudeCodeSubscriptionTests` replay recorded
searches from `EnigmaTests/Fixtures/CloudSearch/`. The opt-in live checks
(`NativeWebSearchLiveTests`) and the quality check
(`NativeWebSearchEvaluationTests`) are in [Testing](Testing.md).

Run them with `scripts/verify-xcode.sh test -only-testing:EnigmaTests/WebSearchTests`.
See [Testing](Testing.md).
