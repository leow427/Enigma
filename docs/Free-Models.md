# Free models

**Free models** gives you cloud models with no paid plan: Gemini's free tier on
your own Google key. When one model reaches its free limit, Enigma moves to the
next most capable one and tells you. Apple's own cloud model (Private Cloud
Compute) joins the list on macOS 27 once Apple grants Enigma access; until then
it is hidden.

## Setting it up

1. Open **Settings → Cloud**, or reach the cloud step of welcome setup (**Want
   backup from the cloud?**). Both show a **Free models** row after ChatGPT and
   Claude.
2. Choose **Get a free Gemini key**. Google AI Studio opens; create a key there.
3. Paste the key into **Paste your Gemini key** and choose **Save**. Enigma
   saves it in the Keychain, makes **Free models** the preferred provider, lists
   the free models and tests the key.

The row then reads **ready · selected for cloud**. If you've chosen another
provider since, **Use Free models** switches back. **Remove key** removes it.
The same key also serves the **Gemini** API provider under **› Advanced**.

## Which model answers

The free models, most capable first:

1. Gemini 3.8 Flash
2. Apple's cloud model (macOS 27, once available; text only, skipped for a
   request with an image)

Older Gemini models are left out on purpose (owner, 2026-10-31). A saved choice
of a model that's no longer offered moves to the top one.

A request goes to the model you chose in ⌘K or **› Advanced**. If that model:

- **reached its free daily limit**, Enigma retries on the next model, says
  **Switched to *next*: *model* reached its free daily limit (resets *time*).**,
  and keeps the next model selected for later requests. ⌘K marks the spent model
  **out until *time***.
- **is busy** (a per-minute limit), Enigma retries on the next model for this
  request only and says **Answered with *next*: *model* is busy right now.**

A reply's label names the model that actually answered. A retry happens only
before anything has streamed or any tool has run, so a tool never runs twice.

When every free model is out, Cloud requests to Free models answer on this Mac
with **Free models are out until *time*. Answered on this Mac.** Free models
never fall back to a paid provider.

## Auto

Auto may use Apple's cloud model. It uses free Gemini models only if you turn on
**Auto may use free Gemini models** in the Free models row (off by default),
because on Google's free tier your prompts may be used to improve Google's
products. With the switch off, or with every free model out, Auto answers on
this Mac. Auto's switches last for one request; they don't change your selected
model.

## Privacy

- On Google's free tier, prompts may be used to improve Google's products. The
  row says so, and Auto stays off Gemini unless you allow it.
- If billing is on for the key's Google project, Google charges for these
  requests.
- Permission cards for Messages name **Google (Gemini's free tier)** as where
  the text goes.
- The key is stored in the Keychain, like the other API keys. See
  [Cloud-Model-Selection.md](Cloud-Model-Selection.md#privacy).

## How it works

- `CloudProviderID.free` is a provider like the others. Its client,
  `FreeModelPool` (`Enigma/Cloud/FreeModelPool.swift`), tries the models in
  order through the Gemini client (and later the Apple one).
- `FreeModelCatalog` (`Enigma/Cloud/FreeModels.swift`) holds the ranking.
  `FreeModelUsage` remembers which models are spent and until when, from
  Google's `QuotaFailure` (`PerDay` quota) and `RetryInfo.retryDelay`; with no
  reset time it waits an hour.
- A daily-limit switch in Cloud mode posts `freeModelSwitched`;
  `CloudSettingsModel` moves the preferred model.
- The Settings and welcome row is `FreeModelsConnectionControls`
  (`Enigma/Cloud/CloudConnectionControls.swift`).

## Limitations

- Only checked against fixtures written from Google's documentation; a live
  check with a real free key is still to do.
- Google sets the free limits and can change them or the models at any time.
- Apple's cloud model needs an entitlement Enigma doesn't have yet.

## Tests

`FreeModelsTests` covers the ranking, quota parsing, the fallback and its
notices, Auto's privacy switch, the all-out local answer, the Settings row, the
key paste and ⌘K's **out until** detail, with offline fakes. Run it with
`scripts/verify-xcode.sh test -only-testing:EnigmaTests/FreeModelsTests`.
