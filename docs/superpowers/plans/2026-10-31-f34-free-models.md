# Free cloud models (F34) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Free models" provider that pools Gemini's free tier and Apple's Private Cloud Compute model, ranked by capability, and steps down the ranking when a model runs out of usage.

**Architecture:** A new `CloudProviderID.free` whose models are plain model IDs (`gemini-2.5-pro`, `apple-pcc`). `FreeModelPool` is its `ChatProvider` and `ToolCallingChatProvider`: it rewrites the route to the underlying Gemini client or calls the Apple client, and on a usage error moves to the next ranked model. Everywhere else that switches on a provider gets one `.free` case that defers to the underlying model.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Foundation Models (macOS 27 SDK only).

**Spec:** [docs/superpowers/specs/2026-10-31-f34-free-models-design.md](../specs/2026-10-31-f34-free-models-design.md)

## Global Constraints

- Deployment target stays macOS 26.0. Anything from the macOS 27 SDK sits inside `#if compiler(>=6.4)` (Xcode 27's Swift; CI's Xcode 26.6 skips it) and `if #available(macOS 27, *)`.
- CI stays on `runs-on: macos-26`.
- Fallback never reaches a paid or subscription route: free models in ranked order, then the local model.
- Free Gemini models are used by Auto only when `autoMayUseFreeGemini` is on (default off). Apple PCC is allowed in Auto.
- No new dependencies. Gemini keys stay in the existing Keychain item for `.gemini`.
- User-facing copy is fixed by the spec; times print with `Date.FormatStyle(time: .shortened)` (e.g. "9:00").
- No attribution lines in commits.

## Deviations from the spec (decided while planning)

1. **Pool model IDs are bare** (`gemini-2.5-pro`, `apple-pcc`), not `gemini/<id>`: the Gemini ID passes through untouched and `apple-pcc` can't collide with a Gemini ID.
2. **The notice rides on `AssistantActivityEvent.notice(String)`**, not a new `ChatEvent` case, so the three exhaustive `ChatEvent` switches in `LocalChatViewModel` don't change.
3. **All free models out, in Cloud mode:** the request that discovers it fails with the stop text below; every later send goes to the local model with the notice, until a reset time passes. Rerunning the failed request on the local model inside `submitNative` would mean re-entering the 2,300-line view model's send path mid-stream. Auto needs no special case: with no Auto-allowed free model left, `autoCloudConfiguration` is nil and Auto answers on this Mac.
4. **Apple's Show options** sits on the Apple line in Settings (shown while `quotaUsage.limitIncreaseSuggestion` exists), not on the notice, which stays plain text.
5. **CI stays on `macos-26`**: GitHub's `xcode-27` preview image failed about 20 screen, panel and Vision tests that pass locally (2026-10-31). The spec's CI section is updated to match.

## Review Focus

1. **A 429 with no parsable body** (proxy, HTML error page): must stay `.rateLimited`, never crash, and still step down for that one request.
2. **The user picks a model in ⌘K that is out of usage:** the pool skips it to the next available model and says so, instead of failing every send until the reset.
3. **The Gemini key is removed while Free models is selected:** Gemini entries disappear; with Apple unavailable, `hasCloudAccess(for: .free)` is false and Cloud mode shows today's "connect" state.
4. **Clock passes the reset time mid-session:** the exhausted model becomes eligible again without a relaunch.
5. **Auto with the toggle off and only Gemini available:** no prompt reaches Google; Auto stays on this Mac.

Each has a test in the task that owns it (Tasks 1, 4, 3, 3 and 5).

## File Structure

| File | Responsibility |
| --- | --- |
| `Enigma/Cloud/FreeModels.swift` (new) | `FreeModelCatalog` (ranking, availability, underlying provider) and `FreeModelUsage` (in-memory reset times) |
| `Enigma/Cloud/FreeModelPool.swift` (new) | `FreeModelPool`: route rewrite, fallback, notices |
| `Enigma/Cloud/ApplePrivateCloudClient.swift` (new, Task 8) | Foundation Models PCC client and tool adapter |
| `Enigma/Cloud/CloudDomain.swift` | `.free` case, `.quotaExhausted` error, 429 parsing |
| `Enigma/Chat/AssistantActivity.swift`, `AssistantActivityView.swift` | notice event and its line |
| `Enigma/Cloud/CloudSettingsModel.swift` | `.free` access, model list, Auto toggle, all-out and Auto pick |
| `Enigma/App/AppShellView.swift` | Auto configuration and Cloud pre-send for `.free` |
| `EnigmaTests/FreeModelsTests.swift` (new) | all F34 unit tests |

---

### Task 1: Usage errors from a 429

**Files:**
- Modify: `Enigma/Cloud/CloudDomain.swift` (`CloudProviderError`, `cloudHTTPError`)
- Create: `EnigmaTests/FreeModelsTests.swift`

**Interfaces:**
- Produces: `CloudProviderError.quotaExhausted(CloudProviderID, resetsAt: Date?)`; `cloudHTTPError(provider:statusCode:data:now:)` with `now: Date = Date()` as a new defaulted parameter, so existing callers don't change.

- [ ] **Step 1: Write the failing tests**

Fixture: Google's documented quota error shape, marked `// synthetic until Task 7 captures a real body`.

```swift
let perDay = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"3600s"}]}}"#
let perMinute = perDay.replacingOccurrences(of: "PerDay", with: "PerMinute").replacingOccurrences(of: "3600s", with: "21s")
let now = Date(timeIntervalSince1970: 1_800_000_000)

func testPerDayQuotaIsExhaustedWithResetTime() {
  XCTAssertEqual(cloudHTTPError(provider: .gemini, statusCode: 429, data: Data(perDay.utf8), now: now),
                 .quotaExhausted(.gemini, resetsAt: now.addingTimeInterval(3600)))
}
func testPerMinuteQuotaStaysRateLimited() {
  XCTAssertEqual(cloudHTTPError(provider: .gemini, statusCode: 429, data: Data(perMinute.utf8), now: now), .rateLimited(.gemini))
}
func testUnparsable429StaysRateLimited() {
  XCTAssertEqual(cloudHTTPError(provider: .gemini, statusCode: 429, data: Data("<html>".utf8), now: now), .rateLimited(.gemini))
}
func testQuotaExhaustedMessageNamesResetTime() {
  let message = CloudProviderError.quotaExhausted(.gemini, resetsAt: now).errorDescription!
  XCTAssertTrue(message.contains(now.formatted(date: .omitted, time: .shortened)))
}
```

- [ ] **Step 2: Run, expect a compile failure** (`quotaExhausted` and `now:` don't exist)

Run: `xcodebuild test -project Enigma.xcodeproj -scheme Enigma -destination 'platform=macOS' -only-testing:EnigmaTests/FreeModelsTests CODE_SIGNING_ALLOWED=NO`

- [ ] **Step 3: Implement**

`quotaExhausted` is per-day only: any `violations[].quotaId` containing `PerDay`. `resetsAt` = `now` + `RetryInfo.retryDelay` (seconds, trailing `s`), or nil without one. Copy: `"\(provider.displayName) reached its free daily limit. It resets at \(time)."`, or `"… limit. Try again later."` when `resetsAt` is nil.

- [ ] **Step 4: Run the tests, expect PASS**

- [ ] **Step 5: Commit** — `git commit -m "Tell a daily usage limit from a per-minute one in 429 errors (F34)"`

### Task 2: Notice line on a reply

**Files:**
- Modify: `Enigma/Chat/AssistantActivity.swift`, `Enigma/Chat/AssistantActivityView.swift`
- Test: `EnigmaTests/FreeModelsTests.swift`

**Interfaces:**
- Produces: `AssistantActivityEvent.notice(String)`; `AssistantActivity.notice: String?` (last notice wins).

- [ ] **Step 1: Failing test**

```swift
func testNoticeIsKeptOnTheActivity() {
  var activity = AssistantActivity(id: UUID())
  activity.apply(.notice("Switched to Apple's cloud model"))
  activity.apply(.phase(.generating))
  XCTAssertEqual(activity.notice, "Switched to Apple's cloud model")
}
```

- [ ] **Step 2: Run, expect a compile failure**
- [ ] **Step 3: Implement.** `apply` stores the notice even after a terminal phase. The view shows it as one secondary-colour line above the activity status, with the existing caption font; VoiceOver reads it as static text.
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** — `"Show a one-line notice above a reply (F34)"`

### Task 3: The Free models provider

**Files:**
- Create: `Enigma/Cloud/FreeModels.swift`
- Modify: `Enigma/Cloud/CloudDomain.swift`, `Enigma/Cloud/CloudModelCatalog.swift`, `Enigma/Cloud/CloudModelCapabilities.swift`, `Enigma/Cloud/CloudSettingsModel.swift`, `Enigma/Chat/ToolPermissions.swift`, `Enigma/Chat/EnigmaConversationLogic.swift`, `Enigma/Screen/ScreenRoutingPolicy.swift`, and every other exhaustive `CloudProviderID` switch the compiler reports
- Modify: `to-do.md` (add the F34 entry in the usual layout; OpenRouter sign-in under Out of scope as a later item)
- Test: `EnigmaTests/FreeModelsTests.swift`

**Interfaces:**
- Produces:
  - `CloudProviderID.free` (raw value `"free"`, `displayName`/`shortName` "Free models")
  - `enum FreeModelCatalog { static let applePCC = "apple-pcc"; static let ranked: [String]; static func available(hasGeminiKey: Bool, appleAvailable: Bool) -> [CloudModel]; static func underlyingProvider(_ modelID: String) -> CloudProviderID? }` — `underlyingProvider` returns `.gemini` for a Gemini ID and nil for `apple-pcc`
  - `final class FreeModelUsage: @unchecked Sendable { static let shared; func markExhausted(_ modelID: String, until: Date?); func isExhausted(_ modelID: String, now: Date) -> Bool; func resetTime(_ modelID: String) -> Date?; func earliestReset(among: [String], now: Date) -> Date? }` — `until: nil` counts as one hour
  - `ToolDestination.apple` (display "Apple")
  - `CloudSettingsModel.autoMayUseFreeGemini: Bool` (`@Published`, saved in defaults, default false) and `var isApplePCCAvailable: Bool` (false until Task 8)

- [ ] **Step 1: Failing tests**

```swift
func testRankingAndAvailability() {
  XCTAssertEqual(FreeModelCatalog.ranked, ["gemini-2.5-pro", "apple-pcc", "gemini-2.5-flash", "gemini-2.5-flash-lite"])
  XCTAssertEqual(FreeModelCatalog.available(hasGeminiKey: true, appleAvailable: false).map(\.id),
                 ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"])
  XCTAssertEqual(FreeModelCatalog.available(hasGeminiKey: false, appleAvailable: true).map(\.id), ["apple-pcc"])
  XCTAssertTrue(FreeModelCatalog.available(hasGeminiKey: true, appleAvailable: true).allSatisfy { $0.provider == .free })
}
func testExhaustionExpiresAtResetTime() {
  let usage = FreeModelUsage(), now = Date()
  usage.markExhausted("gemini-2.5-pro", until: now.addingTimeInterval(60))
  XCTAssertTrue(usage.isExhausted("gemini-2.5-pro", now: now))
  XCTAssertFalse(usage.isExhausted("gemini-2.5-pro", now: now.addingTimeInterval(61)))
}
func testFreeDefersToTheUnderlyingModel() {
  XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .free, modelID: "gemini-2.5-flash"))
  XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .free, modelID: "apple-pcc"))
  XCTAssertEqual(ToolDestination(route: Route(mode: .cloud, providerID: "free", modelID: "apple-pcc", usesNetwork: true)), .apple)
  XCTAssertEqual(ToolDestination(route: Route(mode: .cloud, providerID: "free", modelID: "gemini-2.5-pro", usesNetwork: true)), .google)
}
func testFreeAccessFollowsTheGeminiKey() // with an in-memory credential store: no key → hasCloudAccess(for: .free) false; save a .gemini key → true; remove → false
```

- [ ] **Step 2: Run, expect a compile failure**
- [ ] **Step 3: Implement**
  - Every `.free` switch case defers: `underlyingProvider(id)` gives `.gemini` → the Gemini answer for the same ID. Apple's answers: context 32,768 tokens, 4,096 output, native tools true, images false, reply label `"apple"`, destination `.apple`.
  - `CloudModelCatalog` never fetches for `.free` (throw like `.chatGPT`). `CloudSettingsModel.discoverModels` sets `models = FreeModelCatalog.available(...)` for `.free` without a network call.
  - `hasCloudAccess(.free)` = `hasAPIKey(for: .gemini) || isApplePCCAvailable`.
  - `CloudProviderRegistry.provider(for: .free)` returns a stub that throws `CloudProviderError.invalidResponse` until Task 4 replaces it.
- [ ] **Step 4: Run the tests, then build the app target** (catches switch sites outside the tests). Expect PASS and `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** — `"Add the Free models provider: Gemini free tier, ranked (F34)"`

### Task 4: Fallback in `FreeModelPool`

**Files:**
- Create: `Enigma/Cloud/FreeModelPool.swift`
- Modify: `Enigma/Cloud/CloudProviderClients.swift` (registry holds `free: any ChatProvider`, built from the registry's own Gemini client)
- Test: `EnigmaTests/FreeModelsTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `struct FreeModelPool: ChatProvider, ToolCallingChatProvider { init(gemini: any ToolCallingChatProvider & ChatProvider, apple: (any ToolCallingChatProvider & ChatProvider)?, usage: FreeModelUsage = .shared, models: @Sendable () -> [String], allowsGeminiInAuto: @Sendable () -> Bool, onSwitch: @Sendable (String) -> Void, now: @Sendable () -> Date = Date.init) }`. `models` returns the available ranked IDs; `onSwitch` saves the new choice (the registry passes `setPreferredModel(_:for: .free)` on the main actor).

- [ ] **Step 1: Failing tests.** Fake providers emit scripted events or errors. One test each:
  - `testDailyLimitSwitchesSavesAndRetries`: first model throws `.quotaExhausted(.gemini, resetsAt: t)` before any token → the second model answers, `onSwitch("apple-pcc")` is called once, and the stream's first event is `.activity(.notice("Switched to Apple's cloud model: Gemini 2.5 Pro reached its free daily limit (resets \(t)).")`.
  - `testPerMinuteLimitRetriesWithoutSaving`: `.rateLimited` → the next model answers; `onSwitch` is not called; no exhaustion recorded.
  - `testNoRetryAfterTextStreamed`: the first model yields `.token("Hi")`, then throws → the error reaches the caller and the second model is never called.
  - `testExhaustedChoiceIsSkipped` (Review Focus 2): the chosen model is already exhausted → the next model answers with the notice and `onSwitch` is called.
  - `testAutoSkipsGeminiWithoutTheToggle` (Review Focus 5): route mode `.auto`, toggle off, models `["gemini-2.5-pro", "apple-pcc"]` → only Apple is called.
  - `testAllOutThrowsStopTextWithEarliestReset`: every model exhausted → throws `.quotaExhausted(.free, resetsAt: earliest)`, whose message is `"Free limits reached. They reset at \(time), or connect another provider in Settings."`
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement.** Order = the chosen model, then the rest of `models()` in ranked order, skipping exhausted ones (and Gemini in Auto without the toggle). Gemini requests forward with the route rewritten to `providerID: "gemini"`, keeping the same model ID. Retry only while no `.token` has been yielded and no tool call has started. A notice's model names use `CloudModel.displayName`; Apple's display name is "Apple's cloud model". Add the `.free` copy for `quotaExhausted` to Task 1's message switch.
- [ ] **Step 4: Run, expect PASS**
- [ ] **Step 5: Commit** — `"Step down the free models when one runs out (F34)"`

### Task 5: Auto and the all-out route

**Files:**
- Modify: `Enigma/Cloud/CloudSettingsModel.swift`, `Enigma/App/AppShellView.swift` (`autoCloudConfiguration`, the Cloud send path where `preferredProvider` is read)
- Test: `EnigmaTests/FreeModelsTests.swift`

**Interfaces:**
- Produces: `CloudSettingsModel.autoFreeModelID(now: Date = Date()) -> String?` (the best available, unexhausted, Auto-allowed free model); `CloudSettingsModel.freeModelsAllOut(now: Date = Date()) -> Date?` (the earliest reset when every available free model is exhausted, else nil).

- [ ] **Step 1: Failing tests** on `CloudSettingsModel` with a test `FreeModelUsage` and defaults suite:
  - Toggle off, only a Gemini key → `autoFreeModelID()` is nil. Toggle on → `"gemini-2.5-pro"`.
  - Every available model exhausted → `freeModelsAllOut()` equals the earliest reset; one past its reset → nil (Review Focus 4).
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement.**
  - `autoCloudConfiguration`: for `.free`, use `autoFreeModelID()` as the model; nil when there's none.
  - Cloud mode send with `preferredProvider == .free`, `freeModelsAllOut()` non-nil and a local model installed: send as `.local`, with `.notice("Free models are out until \(time). Answered on this Mac.")` applied to that request's activity.
- [ ] **Step 4: Run the tests and the `CloudModeTests` class, expect PASS**
- [ ] **Step 5: Commit** — `"Keep free Gemini out of Auto unless allowed; answer on this Mac when free models are out (F34)"`

### Task 6: Settings, welcome setup, ⌘K and docs

**Starts after F14's Settings and welcome revamp is merged to `main`; build on its rows and controls.**

**Files:**
- Modify: the Cloud Settings Subscriptions section and welcome setup's Connect step as they exist after F14; the ⌘K model menu
- Create: `docs/Free-Models.md`
- Modify: `docs/Cloud-Model-Selection.md`, `docs/Welcome-and-Settings.md`
- Test: `EnigmaTests/FreeModelsTests.swift`, plus the view test file F14 uses for these rows

**Interfaces:**
- Consumes: `CloudSettingsModel.autoMayUseFreeGemini`, `isApplePCCAvailable`, `FreeModelUsage.resetTime`.
- Produces: `static let FreeModelCatalog.showsApple: Bool = false` (Task 8 sets it true). It hides every Apple line, including the macOS 26 upgrade line, until Apple ships.

- [ ] **Step 1: Failing view tests**
  - The Free models row shows **Get a free Gemini key** with no key saved.
  - Pasting a key saves it to Keychain, tests it, and makes `.free` the preferred provider in one step.
  - The toggle reads **Auto may use free Gemini models**, with the note **On Google's free tier, prompts may be used to improve Google's products.**
  - The billing note reads **If billing is on for this key, Google charges for these requests.**
  - With `showsApple` true on macOS 26, the row says **Update to macOS 27 to get Apple's free cloud model.**
  - ⌘K lists a **Free models** group and marks an exhausted model **out until \(time)**.
- [ ] **Step 2: Run, expect failures**
- [ ] **Step 3: Implement** with F14's existing row components. **Get a free Gemini key** opens `https://aistudio.google.com/apikey`. The same row goes in welcome setup.
- [ ] **Step 4: Run, expect PASS.** Then a manual pass in the app: welcome, Settings, ⌘K, light and dark.
- [ ] **Step 5: Write the docs** from the spec's Fallback, Privacy and UI sections.
- [ ] **Step 6: Commit** — `"Add Free models to Settings, welcome setup and the model menu (F34)"`

### Task 7: Live check with a real free Gemini key

**Needs the owner's free Gemini key saved in Enigma. Never put a key in a shell command.**

- [ ] **Step 1:** Send a normal and a tool-using request through Free models. Expect streamed text and a tool call.
- [ ] **Step 2:** Capture a real daily-limit 429 body: send to the free model with the lowest daily cap until Google refuses, logging only the response body. Replace Task 1's synthetic fixture with it, removing anything that identifies the project. If the quota ID doesn't contain `PerDay`, fix the parser and the test.
- [ ] **Step 3:** Check each `ranked` Gemini ID against the key's model list and Google's free-tier table. Update `ranked` and `docs/Free-Models.md` to match.
- [ ] **Step 4:** Record results in `docs/history/2026-MM-DD-f34-live-check.md` and commit — `"Check free Gemini models live and use a real 429 body (F34)"`

### Task 8: Apple's cloud model

**Starts only after Apple grants `com.apple.developer.private-cloud-compute`.**

**Files:**
- Create: `Enigma/Cloud/ApplePrivateCloudClient.swift`; add the entitlement to the app's entitlements file
- Modify: `CloudSettingsModel.isApplePCCAvailable`, the registry (passes `apple:`), `FreeModelCatalog.showsApple = true`

**Interfaces:**
- Produces: `struct ApplePrivateCloudClient: ChatProvider, ToolCallingChatProvider`, the whole file inside `#if compiler(>=6.4)` and `@available(macOS 27, *)`.

- [ ] **Step 1:** Implement with `LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools:, instructions:)`.
  - Each `AgentToolbox` definition becomes a `Tool` with `GeneratedContent` arguments and a `GenerationSchema` built from its JSON schema (string, number, integer, boolean, array, object and enum).
  - Turn `streamResponse` snapshots into `.token` deltas.
  - Map the framework's usage-limit error, or `quotaUsage.isLimitReached`, to `.quotaExhausted(.free, resetsAt: nil)`.
  - Text only.
  - The Settings Apple line shows **Show options** (calling `suggestion.show()`) while `quotaUsage.limitIncreaseSuggestion` exists.
- [ ] **Step 2:** `isApplePCCAvailable` = `#available(macOS 27, *) && PrivateCloudComputeLanguageModel().isAvailable` (false when compiled without the SDK).
- [ ] **Step 3:** Pool tests from Task 4 still pass. The app builds with Xcode 27.2 locally, and with the `macos-26` CI (Xcode 26.6) with the file compiled out.
- [ ] **Step 4: Manual live check.**
  - A plain answer and a tool call through Apple's model.
  - Xcode's **Simulate Apple Foundation Models Availability → Quota Usage Limit Reached** shows the switch notice, and Apple's **Show options** when `limitIncreaseSuggestion` exists.
- [ ] **Step 5: Commit** — `"Add Apple's cloud model to Free models (F34)"`
