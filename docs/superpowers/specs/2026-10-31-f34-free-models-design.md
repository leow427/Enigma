# Free cloud models (F34) — design

Status: approved design, not yet implemented. Date: 2026-10-31.
Plan: [2026-10-31-f34-free-models.md](../plans/2026-10-31-f34-free-models.md).

## Goal and users

Today every cloud route in Enigma needs something the user pays for or has to
set up: a ChatGPT or Claude plan, or an OpenAI, Anthropic or Gemini API key.
A new user with none of these only has the local model.

F34 gives them free cloud models with as little setup as possible, and when a
free model runs out of usage, moves them to the next most capable free model
instead of failing.

**What the owner asked for (2026-10-31):**

- A "9router mode": free models users sign in to, bundled with the app, with
  no separate install, and only the parts of 9router that are needed.
- When the current free model runs out of usage, switch to the next most
  capable one.
- Gemini, with as little key-fetching as possible, since a key can feel
  intimidating.
- Apple's cloud model, if it can be had for free.
- macOS 26 users are told that upgrading to macOS 27 gives them Apple's free
  model.

**Success means:**

- A user with no plan and no key can reach a free cloud model from welcome
  setup or Settings in one step on macOS 27 (Apple), or in two clicks and a
  paste (Gemini).
- When a free model hits its daily limit, the same request is answered by the
  next model in the ranking, with a one-line notice, and nothing is lost.
- Auto never sends a prompt to a free model whose provider may train on it
  unless the user turned that on.
- Paid and subscription routes are never used without the user choosing them.

## Decisions

Made with the owner on 2026-10-31:

| Topic | Decision |
| --- | --- |
| 9router | Not used. Its free OAuth tiers are mostly discontinued (iFlow, Qwen Code, Gemini CLI), Kiro's free tier is about 50 credits a month, and it signs in with other apps' client IDs, which a signed, public app should not ship. It is also a Node and Next.js server, which would add a runtime and a proxy hop |
| Free sources | Gemini API free tier (user's own key) and Apple Foundation Model on Private Cloud Compute (PCC). OpenRouter is a later sub-project |
| Gemini sign-in | A guided key, not OAuth. Gemini OAuth bills quota to Enigma's own Cloud project (shared by every user), needs Google app verification and shows a broader consent screen |
| Shape | One pseudo-provider, `CloudProviderID.free` (**Free models**), whose models span both sources, ranked by capability |
| Fallback | Free models in ranked order, then the local model. Never a paid or subscription route |
| Daily limit | The switch sticks: the next model is saved as the chosen model, with a notice |
| Per-minute limit | That one request retries on the next model; the choice is not saved |
| Privacy | Apple PCC may be used by Auto like any cloud provider. Free Gemini models are used by Auto only with **Auto may use free Gemini models** on (off by default) |
| macOS 26 | Apple's model is listed only on macOS 27. macOS 26 users see that upgrading to macOS 27 gives them Apple's free model |
| CI | Stays on `macos-26`; the `xcode-27` preview image failed tests that pass locally (see [CI](#ci)) |

**Rejected:**

- Bundling 9router, or porting its Kiro or Antigravity sign-in to Swift: see
  above.
- OpenRouter in the first version: its free models (50 requests a day, 1,000
  after a one-time $10 purchase) often require the account to allow prompt
  logging or training, the weakest privacy of the three. It stays a later
  sub-project with a real OAuth PKCE sign-in if Apple and Gemini are not
  enough.
- Apple as its own provider with the fallback in the callers: the fallback
  would spread across `AppShellView` instead of living in one place.
- Xcode Cloud for CI: needs an App Store Connect app record, is configured
  outside the repo, would not cover the stress and DDGS workflows, and has a
  monthly hour limit.

## Architecture

Everything outside `Enigma/Cloud` routes by `preferredProvider` and
`preferredModelID` (about 15 places in `AppShellView`). The free pool is one
more provider, so none of those callers change except Auto's privacy rule.

| Pool model ID | Runs through | Availability |
| --- | --- | --- |
| `gemini/<model id>` | the existing `GeminiContentClient` and Gemini tool loop, with the saved Gemini key | a Gemini key is saved |
| `apple/pcc` | new `ApplePrivateCloudClient: ChatProvider` using `PrivateCloudComputeLanguageModel` | macOS 27, an Apple Intelligence Mac, the entitlement granted, and `isAvailable` true |

### Units

- **`FreeModelPool: ChatProvider`** (new, `Enigma/Cloud/FreeModelPool.swift`).
  Picks the route from the model ID prefix, streams it, and runs the fallback
  below. It keeps, in memory, the time each exhausted model resets.
- **`ApplePrivateCloudClient`** (new, `Enigma/Cloud/ApplePrivateCloudClient.swift`).
  A `LanguageModelSession(model: PrivateCloudComputeLanguageModel())`.
  Enigma's tools are adapted to Foundation Models' `Tool` protocol with
  `GeneratedContent` arguments and a `GenerationSchema` built from each
  tool's existing JSON schema. Text only until image input is confirmed live.
  Context budget 32,768 tokens. Compiled only with the macOS 27 SDK and
  called only under `#available(macOS 27, *)`.
- **Ranking**: a reviewed order in `CloudModelCatalog`, like the OpenAI
  fallback order. Roughly: the best free Gemini model, Apple PCC, then a
  lighter Gemini Flash model. The Gemini entries are taken from Google's free
  tier list and checked against a real key when this is built; unreviewed
  free-tier models are not listed.
- **`CloudProviderID.free`**: display name **Free models**. Ready when at
  least one pool model is available.

### Errors

- `cloudHTTPError` keeps its signature. For a 429 it also reads the Gemini
  error body: a quota failure whose quota ID names a per-day quota becomes the
  new `CloudProviderError.quotaExhausted(provider, resetsAt: Date?)`; any other
  429 stays `.rateLimited`. The exact quota ID text is taken from a captured
  real 429 before the parser is written, and that body becomes the test
  fixture.
- PCC's usage-limit error, or `quotaUsage.isLimitReached`, maps to
  `.quotaExhausted(.free, resetsAt:)`.
- `ChatEvent` gains `.notice(String)`, shown as one secondary line above the
  reply in the activity-line style.

## Fallback

1. A pool request starts on the chosen model, skipping any model whose reset
   time has not passed.
2. **Daily limit** (`.quotaExhausted`) before any text arrives: record the
   reset time, save the next model as `preferredModelID`, emit a notice, and
   retry the same request on it. Example: **Switched to Apple's cloud model:
   Gemini 2.5 Pro reached its free daily limit (resets 9:00).**
3. **Per-minute limit** (`.rateLimited`) before any text arrives: retry this
   request on the next model without saving it.
4. **After text has streamed**, no retry: the error is shown as today, so an
   answer is never half repeated.
5. **Every free model out**: answer on the local model with the notice **Free
   models are out until 9:00. Answered on this Mac.** With no local model,
   stop with **Free limits reached. They reset at 9:00, or connect another
   provider in Settings.** When PCC offers `limitIncreaseSuggestion`, the
   notice carries Apple's **Show options** button.

The user can always pick another model in ⌘K; a model out of usage shows
**out until 9:00** there.

## Privacy

- **Apple PCC** keeps no prompts, so Auto may use it like any cloud provider.
- **Free Gemini**: Google may use free-tier prompts to improve its products.
  Auto uses these models only when **Auto may use free Gemini models** is on;
  its note says **On Google's free tier, prompts may be used to improve
  Google's products.** Cloud mode uses whatever the user picked, and the note
  is shown once at key setup.
- A Gemini key with billing on is charged for pool requests. Google's API
  can't tell a free key from a billed one, so the row says **If billing is on
  for this key, Google charges for these requests.**
- The Messages and selection rules are unchanged: a chat holding message text
  stays on this Mac in Auto.

## UI

- **⌘K menu**: a **Free models** group in ranked order, each marked **text +
  images** or **text only**, and **out until 9:00** while exhausted.
- **Settings → Cloud** (F14's layout): a **Free models** connection row after
  the ChatGPT and Claude rows, in the same style
  (`CloudConnectionControls.swift`). Free models also joins the **Preferred
  provider** menu under **Advanced** (`CloudProviderID.selectableProviders`
  leaves it out until this row ships).
  - **Gemini**: **Get a free Gemini key** opens Google AI Studio's API key
    page; a paste field saves the key to Keychain, tests it and selects Free
    models in one step, with **Remove**. Uses the same Keychain item as the
    Gemini API-key provider.
  - **Apple**: **ready** on macOS 27 when available; **needs Apple
    Intelligence** on macOS 27 without it; on macOS 26, **Update to macOS 27
    to get Apple's free cloud model.** Before the entitlement is granted the
    Apple line is hidden on every macOS version.
  - **Auto may use free Gemini models** toggle, off by default.
- **Welcome setup, cloud step** (F14's `.connections` step): the same row
  after ChatGPT and Claude, so a user with no plan reaches a cloud model
  during setup. The macOS 26 upgrade line appears here too. The step keeps
  its title **Want backup from the cloud?** and its subtitle becomes **Use
  your ChatGPT or Claude plan, or free models, for the hard stuff. Totally
  optional.** (owner, 2026-10-31).

## CI

CI stays on `runs-on: macos-26` (Xcode 26.6). On 2026-10-31 GitHub's
`xcode-27` preview image (macOS 27.0.1) failed about 20 screen, panel and
Vision tests with both Xcode 27.1 and 27.2 that pass on the owner's Mac, so
the move was reverted. `ApplePrivateCloudClient` sits behind a compile-time
guard (`#if compiler(>=6.4)`), so CI builds without it; the owner's Xcode 27.2
release builds compile it. Move CI once a stable macOS 27 runner exists.

## Testing

Unit tests with fake transports, as the cloud tests do today:

- 429 mapping: per-day Gemini quota → `.quotaExhausted` with reset time;
  per-minute → `.rateLimited`. Fixture: a captured real Gemini 429 body.
- Pool order, and skipping models until their reset time.
- A daily limit saves the next model; a per-minute limit does not.
- No retry once a token has streamed.
- Every model out → local model with notice; no local model → stop message.
- Auto: free Gemini only with the toggle on; Apple PCC always allowed.
- The Apple client is replaced by a fake `ChatProvider` in the pool tests.
  The real client gets a manual live check, including Xcode's **Simulate
  Apple Foundation Models Availability** quota options.

## Build order

1. `.quotaExhausted` mapping and `ChatEvent.notice`.
2. `FreeModelPool` with Gemini only, ranking, Auto toggle.
3. Guided Gemini key UI in Settings and welcome setup, with the macOS 26
   upgrade line hidden until step 4 ships.
4. `ApplePrivateCloudClient`, after Apple grants the entitlement.

Steps 1–3 ship without waiting for Apple.

## Open questions

- **Entitlement for Developer ID apps.** `com.apple.developer.private-cloud-compute`
  is a managed entitlement for apps with fewer than 2 million downloads; one
  Apple page also names the App Store Small Business Program. No Apple page
  says whether Developer ID apps outside the App Store qualify. The owner
  applies through the developer account; step 4 waits on the answer.
- **PCC image input** is suggested by the WWDC26 session but not stated.
- **Gemini free-tier models and limits** change often; the ranking is checked
  when built and with each catalogue update.

## Docs

- New `docs/Free-Models.md`: sources, ranking, fallback, limits, privacy.
- `docs/Cloud-Model-Selection.md`: provider table and Auto rules.
- `docs/Welcome-and-Settings.md`: the Free models row.
- `to-do.md`: F34 entry; OpenRouter sign-in noted as a later item.

## Sources

- 9router: <https://github.com/decolua/9router>
- OpenRouter OAuth PKCE: <https://openrouter.ai/docs/use-cases/oauth-pkce>;
  limits: <https://openrouter.ai/docs/api-reference/limits>
- Gemini OAuth: <https://ai.google.dev/gemini-api/docs/oauth>
- WWDC26 Apple Intelligence guide: <https://developer.apple.com/wwdc26/guides/apple-intelligence/>
- WWDC26 session 319, Apple Foundation Model on Private Cloud Compute:
  <https://developer.apple.com/videos/play/wwdc2026/319/>
- PCC entitlement: <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute>
- GitHub runner images: <https://github.com/actions/runner-images>
