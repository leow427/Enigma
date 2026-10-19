# Local Model Recommendations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recommend the smartest local model each Mac runs fast, from a refreshed seven-family catalogue, in one place (Settings → Local models, with Welcome and the ⌘K sheet showing the same three roles), on llama.cpp b11734.

**Architecture:** `LocalMultimodalProfile` gains each model's KV-cache layout, active parameters and image batch, and computes the new memory estimate. `LocalHardwareProfile` gains a Metal-measured bandwidth, cached per fingerprint and power mode in `hardware.json`. `LocalModelSelector` turns bandwidth, active weight bytes and calibrating benchmarks into speed estimates, picks one quantization per family and fills three roles (`LocalModelRecommendations.roles`) that Settings, Welcome and the ⌘K sheet all render. The catalogue becomes `LocalModelFamily` values that expand into the existing `LocalModelDescriptor`s, so install, verification and runtime code stay as they are.

**Tech Stack:** Swift 6, SwiftUI, Metal (a blit copy for the bandwidth test), XCTest, llama.cpp `llama-server` b11734, Python 3 standard library (the catalogue header script).

**Spec:** `docs/superpowers/specs/2026-10-19-local-model-recommendations-design.md` — read it first. Where this plan refines it, the plan wins; each refinement is listed here so a reviewer can check it:

1. **Gemma's image batch.** Since b11327 llama.cpp caps image tokens at the physical batch for models whose image tokens use non-causal attention (Gemma 4 12B, 26B-A4B, 31B; not E2B/E4B or Qwen). Those profiles launch with `--ubatch-size 1024 --image-max-tokens 1024`, which holds a 1,568-pixel screenshot (about 33 × 21 tokens of 48 px). llama.cpp sizes a sliding-window cache as window + physical batch, and the prompt graph reserves logits for the whole batch, so those profiles' sliding layers hold window + 1,024 tokens and their reserve is 1.5 GiB + 0.5 GiB. The recorded-peak estimates therefore become 9.41 GiB (Gemma 4 12B QAT, peak 8.57) and 7.51 GiB (E4B, peak 6.64), not the spec's 8.76 / 7.54; both stay inside the spec's 0–25 % band.
2. **Expected picks.** With pinned sizes and (1), three rows of the spec's table change: 32 GB M2 Max → Gemma 4 12B Q8_0 (26B-A4B Q4_K_M no longer fits 18.94 GiB), 36 GB M3 Pro → Gemma 4 26B-A4B Q4_K_M, 128 GB M5 Max → Qwen3.8 27B Q5_K_M (the pinned Q5 file is smaller than researched). The 24 GB M5 Pro row is unchanged. Tests use the plan's values.
3. **Gemma quantizations** are `Q4_0, Q4_K_M, Q5_K_M, Q8_0`: Q8_0 is added and Q4_0 kept so installed Gemma QAT packages and the legacy test fixtures stay compatible.
4. **Total and active parameters live on `LocalMultimodalProfile`** (a family reads them from its profile), because old benchmarks must resolve them too.
5. **A request for the removed destination**: destinations are a typed enum, so the only representable stale request is the raw string `"discover"`; it opens Local models.
6. **Qwen3.8 27B Q4_K_M / Q5_K_M are Unsloth Dynamic files** (`UD-Q4_K_M`, `UD-Q5_K_M`), the only Q4/Q5 files in that repository; the package quantization labels stay `Q4_K_M` / `Q5_K_M`.
7. **Multi-token-prediction layers** of Qwen3.6 and Qwen3.8 are attention layers in llama.cpp and are counted in the KV cache (11 and 17 attention layers).

## Global Constraints

- Branch `feat/local-model-recommendations` in its own worktree. Do not push and do not touch `main`.
- Swift 6 (`SWIFT_VERSION = 6.0`), macOS 26. No new dependencies.
- `Enigma.xcodeproj` uses explicit file references (no synchronized folders). Each added file needs four entries in `project.pbxproj`: a `PBXBuildFile`, a `PBXFileReference` (`sourceTree = SOURCE_ROOT`, path from the repo root), a child in its group and an entry in the target's Sources phase; copy how `LocalModelSettingsLogic.swift` (app) and `InstallLocationTests.swift` (tests) appear. A removed file loses all four. Build after every project edit.
- Context stays 8,192 tokens; `inferenceMemoryBudget` is unchanged.
- Gates and constants, verbatim from the spec: fast = estimated ≥ 20 tok/s **and** first token ≤ 2 s on a 256-token prompt; usable = ≥ 8 tok/s; Faster = ≥ 1.5× Recommended's speed, only while Recommended is under 40 tok/s; efficiency 0.75 dense, 0.45 mixture-of-experts; prompt tok/s = 1.3 × bandwidth × 7 ÷ active parameters (billions); TTFT = 256 ÷ prompt tok/s + 1 ÷ decode tok/s; runtime reserve 1.5 GiB; bandwidth clamped to 50–1,500 GB/s.
- Bandwidth is in GB/s (10⁹ bytes/s); byte counts divide by 10⁹ for speed and by `LocalHardwareProfile.gib` for memory.
- Role tags, exactly: `recommended`, `faster`, `smarter, slower replies`; a Recommended that is not fast is tagged `best available, expect longer waits`.
- Existing package IDs and pins stay: `qwen3.5-4b-q4_k_m`, `qwen3.5-4b-q5_k_m`, `qwen3.5-4b-q8_0`, `qwen3.5-9b-q5_k_m`, `gemma-4-12b-q5_k_m`, `gemma-4-26b-a4b-q4_k_m`.
- Privacy and latency: Enigma contacts `huggingface.co` only to install a catalogue package. The bandwidth test makes no network requests, runs off the main thread, at most once per hardware fingerprint and Low Power Mode state, and again only on **Check this Mac**.
- Tests are offline and deterministic. No suite touches the GPU: only `LocalModelAdvisor.shared` gets the real probe; tests inject a closure. The one real probe test runs only with `TEST_RUNNER_ENIGMA_BANDWIDTH_PROBE=1`.
- Copy uses ASCII apostrophes in new strings unless the surrounding view already uses `’`.
- Commits: short imperative sentences, focused, no `Co-Authored-By` or "Generated with" lines. Check `git status` before each commit.
- Verification: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/<Suite>` while developing; `scripts/verify-xcode.sh build`, `test`, `analyze` in Task 9.
- Docs contain no home-directory paths or other private details.

## Review Focus

1. **Packages that leave the catalogue are still installed on people's Macs** (Gemma 4 12B QAT Q4_0, Gemma 4 E4B, Ministral 3, SmolVLM2, MiniCPM-o). They must appear under **On this Mac** with Use and Delete and keep launching on their own runtime. Task 7 test `testOnThisMacKeepsPackagesThatLeftTheCatalogue`.
2. **Files saved by 0.10.x decode**: `hardware.json` without `measuredBandwidth`, `benchmarks.json` without the new benchmark fields, installed descriptors without `activeParameterBillions`. Tests in Tasks 3, 4 and 6.
3. **Benchmarks of imported GGUFs** (`modelByteCount` 0, architecture `unverified`, `parameterBillions` 0) must never calibrate, or every estimate becomes 0 or infinite. Task 4 test `testImportedModelBenchmarksNeverCalibrate`.
4. **A Mac where the Metal test fails** (no device, a command-buffer error, an absurd reading) must still finish **Check this Mac** promptly, with `measuredBandwidth` nil and the core-count prior in use. Task 3 tests `testFailedProbeLeavesBandwidthNil` and `testNoMetalDeviceMeasuresNothing`.
5. **After the runtime bump every installed catalogue package needs an update** (its package revision includes the runtime build), which re-downloads the model. Its **On this Mac** row must still offer Use for the installed copy while **For this Mac** offers Update. Task 7 test `testInstalledPackageNeedingUpdateCanStillBeUsed`. (The re-download itself is today's behavior for any runtime bump and is out of scope; Task 8 puts it in the release notes.)

---

### Task 1: Profile cache layouts and the new memory estimate

**Files:**
- Create: `Enigma/LocalInference/LocalMultimodalProfile.swift` (move `enum LocalMultimodalProfile` here from `LocalModelManifest.swift`, add `LocalCacheLayout`)
- Modify: `Enigma/LocalInference/LocalModelManifest.swift` (remove the moved enum only)
- Create: `EnigmaTests/LocalModelEstimateTests.swift`
- Modify: `EnigmaTests/LocalModelSelectionTests.swift` (the two `cacheBytesPerToken` assertions in `testEveryFamilyHasAReviewedMemoryFloorAndRejectsMismatchedProfiles`)
- Modify: `Enigma.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  ```swift
  /// F16 K and V cache shape, read from the model's GGUF header.
  struct LocalCacheLayout: Sendable, Equatable {
    var fullLayers: Int
    var fullKVHeads: Int
    var fullHeadDimension: Int
    var slidingLayers = 0
    var slidingKVHeads = 0
    var slidingHeadDimension = 0
    var slidingWindow = 0
    /// Full layers hold `context` tokens; sliding layers hold
    /// min(context, roundUp(slidingWindow + physicalBatch, 256)). 4 bytes per head dimension (K + V at F16).
    func bytes(context: Int, physicalBatch: Int) -> Int64
  }
  extension LocalMultimodalProfile {   // inside the enum in the new file
    // new cases, appended after the existing ones:
    case qwen35_2B, qwen36_35BA3B, qwen38_27B
    static let defaultPhysicalBatch = 512
    var activeParameters: Double
    var isMixtureOfExperts: Bool
    var cacheLayout: LocalCacheLayout
    var usesNonCausalImageAttention: Bool
    var physicalBatchSize: Int     // 1024 when usesNonCausalImageAttention, else 512
    var imageMaxTokens: Int        // 1024 when usesNonCausalImageAttention, else 4096
    var runtimeReserve: Int64      // 1.5 GiB + (physicalBatchSize - 512) * 1_048_576
    func memory(weights: Int64, projector: Int64, context: Int) -> Int64
    // = weights + projector + cacheLayout.bytes(context:physicalBatch: physicalBatchSize) + runtimeReserve
  }
  ```
  `cacheBytesPerToken` is removed. `1_048_576` is one F32 logits row of Gemma 4's 262,144-token vocabulary; say so in a comment.

- [ ] **Step 1: Write the failing tests** in `LocalModelEstimateTests` (XCTest, `@testable import Enigma`).
  - `testCacheLayoutsMatchTheGGUFHeaders` — exact `cacheLayout` for each profile (window 0 and sliding 0 unless given):

    | Profile | full (layers × KV heads × dim) | sliding (layers × KV heads × dim, window) |
    |---|---|---|
    | `qwen35_2B` | 6 × 2 × 256 | — |
    | `qwen35_4B`, `qwen35_9B` | 8 × 4 × 256 | — |
    | `qwen36_35BA3B` | 11 × 2 × 256 | — |
    | `qwen38_27B` | 17 × 4 × 256 | — |
    | `gemma4_12B` | 8 × 1 × 512 | 40 × 8 × 256, 1024 |
    | `gemma4A4B` | 5 × 2 × 512 | 25 × 8 × 256, 1024 |
    | `gemma4E4B` | 7 × 2 × 512 | 35 × 2 × 256, 512 |

  - `testCacheBytesAtTheDefaultContext` — `profile.cacheLayout.bytes(context: 8192, physicalBatch: profile.physicalBatchSize)`: `qwen35_2B` 100_663_296; `qwen35_4B` 268_435_456; `qwen36_35BA3B` 184_549_376; `qwen38_27B` 570_425_344; `gemma4_12B` 805_306_368; `gemma4A4B` 587_202_560; `gemma4E4B` 308_281_344. And `gemma4_12B` at `context: 4096` → 738_197_504.
  - `testSlidingLayersFollowThePhysicalBatch` — `LocalMultimodalProfile.gemma4_12B.cacheLayout.bytes(context: 8192, physicalBatch: 512)` == 637_534_208 and with `physicalBatch: 1024` == 805_306_368; `qwen35_4B` doubles exactly from context 4096 to 8192.
  - `testGemmaImageBatchAndReserve` — `usesNonCausalImageAttention` true only for `gemma4_12B`, `gemma4A4B`, `gemma4_31B`; their `physicalBatchSize` 1024 and `imageMaxTokens` 1024; `qwen35_4B` 512 / 4096; `runtimeReserve` 2_147_483_648 for `gemma4_12B`, 1_610_612_736 for `qwen35_4B` and `gemma4E4B`.
  - `testEstimatesCoverTheRecordedPeaks` — Gemma 4 12B QAT on the owner's Mac: `gemma4_12B.memory(weights: 6_975_879_296, projector: 175_115_616, context: 8192)` == 10_103_784_928, ≥ 9_206_136_832 and ≤ 9_206_136_832 × 1.25. Gemma 4 E4B QAT: `gemma4E4B.memory(weights: 5_154_941_280, projector: 991_552_256, context: 8192)` == 8_065_387_616, ≥ 7_132_168_192 and ≤ 7_132_168_192 × 1.25.
  - `testWeightsAndProjectorCountOnce` — adding 1 GiB to `weights` (or to `projector`) raises `memory` by exactly 1 GiB.
  - `testParametersKindsAndFormats` — `parameters`: `qwen35_2B` 2.27, `qwen35_4B` 4.66, `qwen35_9B` 9.65, `gemma4_12B` 12, `gemma4A4B` 25.2, `qwen36_35BA3B` 36, `qwen38_27B` 27.8. `activeParameters`: `gemma4A4B` 3.8, `qwen36_35BA3B` 3, `gemma4E4B` 4.5, `gemma4E2B` 2.3, every other profile equals `parameters`. `isMixtureOfExperts` true for exactly `gemma4A4B` and `qwen36_35BA3B`. `architecture`: `qwen35_2B` and `qwen38_27B` `"qwen35"`, `qwen36_35BA3B` `"qwen35moe"`. `chatTemplate` `"qwen3.5"` for all five Qwen3.5/3.6/3.8 profiles. `quantizations`: every `gemma4*` `["Q4_0", "Q4_K_M", "Q5_K_M", "Q8_0"]`, `qwen35_2B` `["Q4_K_M", "Q8_0"]`, the rest unchanged.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelEstimateTests`
Expected: build fails (`LocalCacheLayout`, `qwen35_2B`, `cacheLayout` not found).

- [ ] **Step 3: Implement** `Enigma/LocalInference/LocalMultimodalProfile.swift` with the interfaces above. Layouts for the profiles not in the table convert today's `cacheBytesPerToken` into full layers (`qwen3VL4B`, `qwen3VL8B`, `miniCPMV45`, `miniCPMO45` 36 × 8 × 128; `qwen3VL32B` 64 × 8 × 128; `ministral3B` 26 × 8 × 128; `ministral8B` 34 × 8 × 128; `ministral14B` 40 × 8 × 128; `miniCPMV4` 32 × 2 × 128; `smolVLM2` 24 × 32 × 64), and `gemma4E2B` 7 × 1 × 512 + 28 × 1 × 256 window 512, `gemma4_31B` 10 × 4 × 512 + 50 × 16 × 256 window 1024 (both unverified against a header; comment that). Comment on the Qwen layouts that Gated DeltaNet layers keep a small recurrent state inside the reserve and that the MTP layer is counted. Replace the type's doc comment with one saying the layouts come from the GGUF headers (`scripts/gguf-header.py`, Task 6) and that Gemma global layers count K and V separately (conservative). Add the file to the project.

- [ ] **Step 4: Update the two old assertions** in `testEveryFamilyHasAReviewedMemoryFloorAndRejectsMismatchedProfiles` to `XCTAssertEqual(LocalMultimodalProfile.ministral14B.cacheLayout.bytes(context: 8192, physicalBatch: 512), 1_342_177_280)` and `XCTAssertEqual(LocalMultimodalProfile.gemma4E4B.cacheLayout.bytes(context: 8192, physicalBatch: 512), 308_281_344)`.

- [ ] **Step 5: Run the estimate, selection and vision suites**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelEstimateTests -only-testing:EnigmaTests/LocalModelSelectionTests -only-testing:EnigmaTests/LocalVisionTests`
Expected: `** TEST SUCCEEDED **`. If an existing test fails only because it asserted an old estimate value, change that value to the new formula's (for example `moe.estimatedRuntimeMemory > 20 * gib` becomes `> 19 * gib`: Gemma 4 26B-A4B Q4_K_M is now 19.52 GiB); any other failure is a code bug.

- [ ] **Step 6: Commit** — `git commit -m "Estimate memory from each model's cache layout"`.

---

### Task 2: llama.cpp b11734 and Gemma's image batch

**Files:**
- Modify: `Enigma/LocalInference/LlamaServerVisionEngine.swift` (`LocalVisionRuntime`, `LlamaServerVisionEngine.arguments`)
- Modify: `Enigma/Resources/ThirdPartyNotices.txt` (`b10797` → `b11734`)
- Test: `EnigmaTests/LocalVisionTests.swift`

**Interfaces:**
- Consumes: Task 1's `LocalMultimodalProfile.usesNonCausalImageAttention`, `physicalBatchSize`, `imageMaxTokens`.
- Produces: `LocalVisionRuntime.build == 11734`, `LocalVisionRuntime.directoryName == "llama-b11734"`, and
  ```swift
  extension LlamaServerVisionEngine {
    /// ["--ubatch-size", "1024", "--image-max-tokens", "1024"] for non-causal image attention, else ["--image-max-tokens", "4096"].
    static func imageArguments(for profile: LocalMultimodalProfile?) -> [String]
  }
  ```
  `arguments(model:port:key:alias:)` keeps its signature and every current argument through `"--fit", "off"`, then appends `imageArguments(for: model.catalogDescriptor?.resolvedProfile)`.

Pinned (GitHub release b11734, published 2026-10-19; tarball root `llama-b11734/` confirmed for both):

| Arch | URL | Bytes | SHA-256 |
|---|---|---|---|
| arm64 | `https://github.com/ggml-org/llama.cpp/releases/download/b11734/llama-b11734-bin-macos-arm64.tar.gz` | 12292927 | `c823aad1d1c40728e8f1565663078fa2b3b7fd06bf484fa43e9e48b8b1b2509c` |
| x64 | `https://github.com/ggml-org/llama.cpp/releases/download/b11734/llama-b11734-bin-macos-x64.tar.gz` | 11781759 | `696521c81f21816e5b7686aa308425004ee1ec1fc2d2679414e9e6fa0aa8fbfc` |

Every flag Enigma passes exists in b11734's `common/arg.cpp` (checked, including `-ub/--ubatch-size` and `--image-max-tokens`); `--mmap` is gone there and Enigma never used it. The default-port change (b11521) does not matter because Enigma always passes `--port`.

- [ ] **Step 1: Write the failing tests** in `LocalVisionTests`.
  - In `testServerLaunchUsesModelAndProjectorOfflineOnLoopback` add: the fixture (no catalogue descriptor) has `--image-max-tokens` followed by `"4096"` and no `--ubatch-size`.
  - `testGemmaLaunchKeepsWholeScreenshotsInOneBatch`: the same fixture with `catalogDescriptor` set to the bundled `gemma-4-12b-q5_k_m` → the arguments contain `--ubatch-size` followed by `"1024"` and `--image-max-tokens` followed by `"1024"`; with `qwen3.5-4b-q5_k_m` → `--image-max-tokens` `"4096"`, no `--ubatch-size`. `XCTAssertEqual(LlamaServerVisionEngine.imageArguments(for: nil), ["--image-max-tokens", "4096"])`.
  - `testLaunchUsesOnlyArgumentsTheRuntimeKnows`: for both descriptors, every argument that starts with `-` is in `["-m", "--mmproj", "--host", "--port", "--api-key", "--alias", "--ctx-size", "--parallel", "--offline", "--no-webui", "--jinja", "--no-context-shift", "--cache-ram", "--reasoning-budget", "--fit", "--image-max-tokens", "--ubatch-size"]` (the value `"-1"` after `--reasoning-budget` is a value, skip it), and none is `--mmap`, `--no-mmap`, `--mlock` or `-dio`.
  - In `testBundledVisionPackagesPinMatchingPairsAndOfficialRuntime` change `"b10797"` to `"b11734"` and add `XCTAssertEqual(LocalVisionRuntime.directoryName, "llama-b11734")`.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalVisionTests`
Expected: FAIL (`imageArguments` not found).

- [ ] **Step 3: Implement** the pins and `imageArguments(for:)`; update the notices file.

- [ ] **Step 4: Run the vision and selection suites**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalVisionTests -only-testing:EnigmaTests/LocalModelSelectionTests`
Expected: `** TEST SUCCEEDED **`. Benchmarks in the selection tests are built from `model.runtimeBuild`, so they follow the bump; the legacy Qwen3-VL fixture pinned to 10797 is meant to be unsupported.

- [ ] **Step 5: Commit** — `git commit -m "Move the local runtime to llama.cpp b11734"`.

---

### Task 3: Measured memory bandwidth

**Files:**
- Create: `Enigma/LocalInference/LocalBandwidthProbe.swift`
- Modify: `Enigma/LocalInference/LocalHardwareProfile.swift`, `Enigma/LocalInference/LocalModelAdvisor.swift`
- Create: `EnigmaTests/LocalBandwidthProbeTests.swift`
- Modify: `Enigma.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  ```swift
  // LocalHardwareProfile: not part of `fingerprint`; old hardware.json decodes it as nil.
  var measuredBandwidth: Double? = nil   // GB/s

  enum LocalBandwidthProbe {
    static let validRange: ClosedRange<Double> = 50...1_500
    /// Largest finite positive pass, clamped into validRange; nil when there is none.
    static func best(of passes: [Double]) -> Double?
    /// Five blit passes on the GPU; nil without a device or on any command-buffer error.
    static func measure(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) -> Double?
  }

  // LocalModelAdvisor
  init(directory:modelsDirectory:defaults:trust:detect:
       measureBandwidth: (@Sendable () -> Double?)? = nil)   // new last parameter; nil never measures
  static let shared = LocalModelAdvisor(measureBandwidth: { LocalBandwidthProbe.measure() })
  func detectHardware(remeasureBandwidth: Bool = false) async
  ```

- [ ] **Step 1: Write the failing tests** in `LocalBandwidthProbeTests` (`@MainActor` where they use the advisor). Each advisor test uses a fresh temporary `directory`, `trust: nil`, an injected `detect` returning a fixed profile, and a `measureBandwidth` closure that counts its calls (a `Sendable` box with a lock, or an actor read after `await`).
  - `testBestPassIsClampedIntoTheValidRange`: `best(of: [100, 250, 240]) == 250`; `best(of: [2_000]) == 1_500`; `best(of: [10]) == 50`; `best(of: [.nan, -1, 0, .infinity]) == nil`; `best(of: []) == nil`.
  - `testNoMetalDeviceMeasuresNothing`: `LocalBandwidthProbe.measure(device: nil) == nil`.
  - `testBandwidthIsMeasuredOncePerFingerprintAndPowerMode`: closure returns 267. `detectHardware()` twice → 1 call, `hardware?.measuredBandwidth == 267`. A second advisor on the same directory → `detectHardware()` makes 0 more calls and reads 267 from `hardware.json`. Switch the injected profile to `lowPowerMode: true` → 1 more call. `detectHardware(remeasureBandwidth: true)` → 1 more call (3 total).
  - `testFailedProbeLeavesBandwidthNil`: closure returns nil → `detectHardware()` completes with `hardware != nil`, `measuredBandwidth == nil`, `isDetecting == false`; the next `detectHardware()` calls the closure again (a failure is not cached).
  - `testAdvisorWithoutAProbeNeverMeasures`: advisor built without `measureBandwidth` → `measuredBandwidth == nil`.
  - `testFingerprintIgnoresMeasuredBandwidth`: two profiles that differ only in `measuredBandwidth` have equal `fingerprint`.
  - `testHardwareReportsWithoutBandwidthStillDecode`: encode a profile, delete the `measuredBandwidth` key from the JSON, decode → equal to the original with nil bandwidth.
  - `testMetalProbeOnThisMac` (opt-in): `guard ProcessInfo.processInfo.environment["ENIGMA_BANDWIDTH_PROBE"] == "1" else { throw XCTSkip(...) }`; `measure()` returns a value in `validRange`, taking under 0.25 s (wall clock).

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalBandwidthProbeTests`
Expected: build fails (`LocalBandwidthProbe` not found).

- [ ] **Step 3: Implement `LocalBandwidthProbe`.** Two `.storageModePrivate` buffers of 256 MiB. One pass is one command buffer with a blit encoder copying A→B then B→A (1 GiB of traffic: 512 MiB read, 512 MiB written). Run five passes, drop the first as warm-up, and for each `status == .completed` pass compute `4 × length ÷ (gpuEndTime − gpuStartTime) ÷ 1e9`; any other status → return nil. Return `best(of:)`. No logging of anything but a failure line.

- [ ] **Step 4: Implement the advisor and profile changes.** `detectHardware(remeasureBandwidth:)` runs `detect` and, in the same detached utility task, the probe; it reuses the bandwidth of the in-memory `hardware` or, failing that, of the saved `hardware.json` when that profile's `fingerprint` and `lowPowerMode` match the fresh one, the saved bandwidth is non-nil, and `remeasureBandwidth` is false. Then it saves as today. Add the new file to the project.

- [ ] **Step 5: Run the probe and selection suites**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalBandwidthProbeTests -only-testing:EnigmaTests/LocalModelSelectionTests`
Expected: `** TEST SUCCEEDED **` (the opt-in test skipped).

- [ ] **Step 6: Commit** — `git commit -m "Measure memory bandwidth with Metal"`.

---

### Task 4: Speed estimates and calibration

**Files:**
- Modify: `Enigma/LocalInference/LocalModelSelection.swift` (`prediction` → `estimate`, `LocalModelAssessment`)
- Modify: `Enigma/LocalInference/LocalModelManifest.swift` (`LocalModelDescriptor`)
- Modify: `Enigma/LocalInference/LocalModelBenchmark.swift`, `Enigma/LocalInference/LocalModelAdvisor.swift` (`record`)
- Test: `EnigmaTests/LocalModelEstimateTests.swift`, `EnigmaTests/LocalModelSelectionTests.swift`

**Interfaces:**
- Consumes: Task 1's `activeParameters`, `isMixtureOfExperts`; Task 3's `measuredBandwidth`.
- Produces:
  ```swift
  // LocalModelDescriptor (new stored field optional, so installed records decode)
  var activeParameterBillions: Double? = nil
  var resolvedActiveParameterBillions: Double { get }   // activeParameterBillions ?? parameterBillions
  var isMixtureOfExperts: Bool { get }                  // resolvedProfile?.isMixtureOfExperts ?? false
  var activeWeightBytes: Double { get }                 // expectedByteCount × resolvedActive ÷ parameterBillions
  // validate(): activeParameterBillions, when present, is finite, > 0 and ≤ parameterBillions

  // LocalModelBenchmark (version stays 1)
  var activeParameterBillions: Double? = nil
  var isMixtureOfExperts: Bool? = nil
  /// isApplicable without the runtime-build check; also requires modelByteCount > 0 and parameterBillions > 0.
  func isApplicableForCalibration(to hardware: LocalHardwareProfile, now: Date = .now) -> Bool
  var calibrationProfile: LocalMultimodalProfile? { get }
  var calibrationActiveParameterBillions: Double { get }
  var calibrationActiveWeightBytes: Double { get }
  var calibrationIsMixtureOfExperts: Bool { get }

  // LocalModelSelector
  static let denseEfficiency = 0.75
  static let mixtureEfficiency = 0.45
  static let promptFactor = 1.3
  static func bandwidth(for hardware: LocalHardwareProfile) -> Double
  static func calibration(for model: LocalModelDescriptor, from benchmarks: [LocalModelBenchmark]) -> LocalModelBenchmark?
  static func estimate(_ model: LocalModelDescriptor, hardware: LocalHardwareProfile,
                       calibration benchmarks: [LocalModelBenchmark]) -> (speed: Double, ttft: Double)

  // LocalModelAssessment
  var isFast: Bool { get }     // fit.canRun && tokensPerSecond >= 20 && timeToFirstToken <= 2
  var isUsable: Bool { get }   // fit.canRun && tokensPerSecond >= 8
  ```
  `isResponsive` stays until Task 5.

Rules the signatures do not determine:
- `bandwidth(for:)`: `measuredBandwidth` as is when present (it was measured in the current power mode); otherwise today's prior, `hasMetal ? min(100, 18 + 5 × cores) : min(16, 2 × cores)` with `cores = max(1, min(performanceCPUCount, cpuCount))`, × 0.65 in Low Power Mode.
- `calibrationProfile`: the profile of the bundled descriptor with the same `modelID`; otherwise the `LocalMultimodalProfile` whose `architecture` and `parameters` equal the record's; otherwise nil. Active fraction: recorded `activeParameterBillions ÷ parameterBillions` when the record has it, else `profile.activeParameters ÷ profile.parameters`, else 1. `calibrationActiveParameterBillions`: recorded value, else `profile.activeParameters`, else `parameterBillions`. `calibrationIsMixtureOfExperts`: recorded, else profile, else false.
- `calibration(for:from:)`: among benchmarks of the same kind (`calibrationIsMixtureOfExperts == model.isMixtureOfExperts`), the latest by `recordedAt` with the same architecture, else the latest of that kind, else nil. Callers pass only benchmarks already filtered with `isApplicableForCalibration`.
- `estimate`: with bandwidth `B` from `bandwidth(for:)` and calibrating benchmark `C`: efficiency = `C.metrics.generationTokensPerSecond × C.calibrationActiveWeightBytes ÷ (B × 1e9)`, else 0.75 / 0.45; factor = `C.metrics.promptTokensPerSecond × C.calibrationActiveParameterBillions ÷ (B × 7)`, else 1.3. Decode = `B × 1e9 × efficiency ÷ model.activeWeightBytes`; prompt = `factor × B × 7 ÷ model.resolvedActiveParameterBillions`; TTFT = `256 / max(1, prompt) + 1 / max(0.1, decode)`. No cap. No Low Power Mode factor here (it is inside `bandwidth(for:)`).
- `assess` keeps exact measurements (`isApplicable`, same checksum and context) overriding both values, and passes `measurements.filter { $0.isApplicableForCalibration(to: hardware) }` to `estimate`.
- `LocalModelAdvisor.record` fills the two new benchmark fields from the descriptor (`resolvedActiveParameterBillions`, `isMixtureOfExperts`); nil without a descriptor.
- `performanceDescription` keeps its text but chooses "Responsive everyday chat" by `isFast`.

- [ ] **Step 1: Write the failing tests** in `LocalModelEstimateTests`. Fixture `ownersMac`: `physicalMemory 25_769_803_776`, `metalRecommendedWorkingSet 19_069_665_280`, `metalMaximumBufferLength 14_302_248_960`, `cpuCount 18`, `performanceCPUCount 6`, Apple Silicon, Metal, unified memory, `lowPowerMode false`, `availableDiskBytes 500 GiB`, `chip "Apple M5 Pro"`, `device "Mac17,9"`, `measuredBandwidth 267`. Packages from `LocalModelManifest.bundled` by ID: `gemma-4-12b-q5_k_m`, `gemma-4-26b-a4b-q4_k_m`, `qwen3.5-4b-q5_k_m`, `qwen3.5-4b-q8_0`. Benchmark helper `record(id:architecture:bytes:parameters:speed:prompt:build:recordedAt:)` with the fixture's fingerprint, valid metrics (`promptTokenCount 140`, `generatedTokenCount 64`, `peakMemoryBytes 9_206_136_832`). The owner's runs: Gemma 4 12B QAT `("gemma-4-12b-it-qat-q4_0-gguf", "gemma4", 6_975_879_296, 12, 33.16531329376308, 234.52804679524323, 10797)` recorded one hour ago, Gemma 4 E4B QAT `("gemma-4-e4b-it-qat-q4_0-gguf", "gemma4", 5_154_941_280, 7.5, 67.19727627040184, 136.2804710085045, 10797)` recorded two hours ago (so the 12B run is the latest, as on the owner's Mac). Use accuracy 0.01.
  - `testDenseEstimateUsesMeasuredBandwidth`: `gemma-4-12b-q5_k_m` → speed 23.80, TTFT 1.31.
  - `testMixtureOfExpertsReadsOnlyActiveWeights`: `gemma-4-26b-a4b-q4_k_m` → speed 46.77, TTFT 0.42; its `activeWeightBytes` == 17_035_039_872 × 3.8 / 25.2.
  - `testMeasuredRunCalibratesEveryDenseModelWithoutACap`: with the 12B QAT run (build 10797) → `gemma-4-12b-q5_k_m` speed 27.50, TTFT 1.13; `qwen3.5-4b-q8_0` speed 51.61; `gemma-4-26b-a4b-q4_k_m` still 46.77 (other kind). With `measuredBandwidth` nil on the same Mac the 12B estimate is still 27.50 (calibration cancels the bandwidth; the old 2× cap would have held it near 8.6).
  - `testSameArchitectureIsPreferred`: the 12B QAT run plus a later `qwen3.5-4b-q5_k_m` run `("qwen35", 3_143_656_608, 4, 63.0, 300, 10797)` → `gemma-4-12b-q5_k_m` 27.50, `qwen3.5-4b-q8_0` 63.0 × 3_143_656_608 / 4_482_403_488 = 44.18.
  - `testGemmaEModelsCalibrateFromEffectiveParameters`: only the E4B run → `gemma-4-12b-q5_k_m` speed 24.70 (with total parameters it would be 41.17).
  - `testExactMeasurementNeedsTheCurrentRuntime`: a run of `gemma-4-12b-q5_k_m` itself at 30 tok/s with the descriptor's checksum and context: with `build 10797` → `assess(...).isMeasured == false` and speed 30.00 (it calibrates exactly); with `build LocalVisionRuntime.build` → `isMeasured == true`, speed 30.
  - `testImportedModelBenchmarksNeverCalibrate`: a run with `modelByteCount 0`, `parameterBillions 0`, architecture `"unverified"` → `isApplicableForCalibration` false; the 12B estimate is 23.80 and finite.
  - `testPriorBandwidthWithoutAMeasurement`: `ownersMac` without bandwidth → `bandwidth(for:) == 48`; with `lowPowerMode` → 31.2; with `lowPowerMode` and `measuredBandwidth 200` → 200; `hasMetal false`, 6 cores → 12.
  - `testOldBenchmarksDecode`: JSON of a record without the two new keys decodes; `calibrationActiveParameterBillions` for the 12B QAT record is 12, for the E4B record 4.5, and `calibrationIsMixtureOfExperts` false for both.
  - `testRecordedBenchmarksKeepActiveParameters` (in `LocalModelSelectionTests`, beside `testBenchmarksPersistLocallyAndDoNotChangeSelectedModel`): after `advisor.record(...)` for an installed `gemma-4-26b-a4b-q4_k_m`, the saved record has `activeParameterBillions == 3.8` and `isMixtureOfExperts == true`.
  - `testSpeedGates`: an assessment of `gemma-4-12b-q5_k_m` on `ownersMac` is `isFast`; at `measuredBandwidth 60` it is neither fast nor usable (5.35 tok/s); `qwen3.5-4b-q5_k_m` at 60 → usable (14.31) but not fast.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelEstimateTests`
Expected: build fails (`estimate`, `isFast`, `activeWeightBytes` not found).

- [ ] **Step 3: Implement** the interfaces and rules above. In `BundledLocalModels.package(...)` pass `activeParameterBillions: profile.activeParameters` so today's catalogue already carries it.

- [ ] **Step 4: Run the estimate and selection suites**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelEstimateTests -only-testing:EnigmaTests/LocalModelSelectionTests`
Expected: `** TEST SUCCEEDED **`. Selection tests that relied on the old 2× cap or the old prior (`testActualSlowdownChangesRecommendationAndSuggestsSmallerModel`, `testFastRealMeasurementsCanPromoteASmarterModelWithoutOverridingMemorySafety`, `testChipNamesDoNotControlSelectionAndCPUResourcesDo`) may need new numbers; keep each test's intent.

- [ ] **Step 5: Commit** — `git commit -m "Estimate speed from bandwidth and active weights"`.

---

### Task 5: Roles replace tiers

**Files:**
- Modify: `Enigma/LocalInference/LocalModelSelection.swift` (`LocalModelRecommendations`, `LocalModelSelector.select`, remove `isResponsive` and `hardwareOrder`)
- Modify: `Enigma/LocalInference/BundledLocalModels.swift` (remove `LocalModelWeight`, `LocalModelTiers`)
- Modify: `Enigma/LocalInference/LocalModelManifest.swift` (`familyID`)
- Modify: `Enigma/App/WelcomeSetup.swift` (`choices`), `Enigma/App/WelcomeSetupView.swift` (role tags)
- Modify: `Enigma/LocalInference/LocalModelViews.swift` (`LocalModelOnboardingView`), `Enigma/LocalInference/LocalModelManagerSection.swift` (the two tier loops only)
- Test: `EnigmaTests/LocalModelSelectionTests.swift`, `EnigmaTests/EnigmaWelcomeTests.swift`

**Interfaces:**
- Consumes: Task 4's `isFast`, `isUsable`, `estimate`.
- Produces:
  ```swift
  extension LocalModelDescriptor { var familyID: String { displayName } }

  enum LocalModelRole: String, Sendable, CaseIterable {
    case recommended, faster, smarter
    func tag(isFast: Bool) -> String
  }
  struct LocalModelRoleChoice: Identifiable, Sendable {
    let role: LocalModelRole
    let assessment: LocalModelAssessment
    var id: String { assessment.id }
    var tag: String { role.tag(isFast: assessment.isFast) }
  }
  struct LocalModelRecommendations: Sendable {
    let assessments: [LocalModelAssessment]          // every package
    let recommended: LocalModelAssessment?
    let faster: LocalModelAssessment?
    let smarter: LocalModelAssessment?
    var allFamilies: [LocalModelAssessment] = []     // one per family, LocalModelSelector.qualityOrder
    var roles: [LocalModelRoleChoice] { get }        // non-nil recommended, faster, smarter, in that order
    func fasterAlternative(to modelID: String) -> LocalModelAssessment?
  }
  extension LocalModelSelector {
    static let fastTokensPerSecond = 20.0, fastTimeToFirstToken = 2.0, usableTokensPerSecond = 8.0
    static let instantTokensPerSecond = 40.0, fasterSpeedup = 1.5
    /// The family's package: the largest fast package, else the smallest runnable one, else nil.
    static func choice(in family: [LocalModelAssessment]) -> LocalModelAssessment?
  }
  ```
  Removed: `tierGroups`, `otherTierAssessments`, `rankedChoices`, `otherAssessments`, `physicalMemory`, `hardwareOrder`, `isResponsive`, `LocalModelWeight`, `LocalModelTiers`. Callers of `isResponsive` switch to Task 4's `isFast`.

`select` (signature unchanged): assess every package; group by `familyID`; `candidates` = each family's `choice(in:)`; `allFamilies` = each family's choice or, when nil, its package with the smallest `expectedByteCount`, sorted by `qualityOrder`. Recommended = the first fast candidate by `qualityOrder`, else the first usable candidate. When Recommended is fast: Faster = the first fast candidate by `qualityOrder` from another family with speed ≥ 1.5 × Recommended's, only if Recommended < 40 tok/s; Smarter = the first candidate by `qualityOrder` that is usable, not fast and of higher `qualityScore`. When Recommended is not fast, Faster and Smarter are nil. `fasterAlternative(to:)` keeps its rule with `isFast` in place of `isResponsive`. "Largest"/"smallest" compare `expectedByteCount` (higher precision is a larger file within a family).

`WelcomeSetup.choices(_:preserving:)` returns `roles.map(\.assessment)`, then keeps today's preserving rule (append a runnable selected package that is not a role, replacing the last when there are three). Welcome and the ⌘K sheet tag a row with its `LocalModelRoleChoice.tag` (a preserved extra row has none). The sheet drops the `EnigmaHint("Lightweight, middleweight and heavyweight…")` line and shows "No suitable model found" when `roles` is empty. Welcome drops the "Only N compatible choices fit this Mac right now." note (fewer than three roles is normal now) and keeps the empty-state note. In `LocalModelManagerSection` the tier loop becomes `EnigmaSectionHeader("For this Mac")` + one `modelRow` per role with its tag as the badge, and "Models for other memory sizes" becomes `EnigmaDisclosure("All models")` over `allFamilies`; the rest of the page waits for Task 7.

- [ ] **Step 1: Write the failing tests** in `LocalModelSelectionTests`. Add a test helper `familyPackage(family: String, profile: LocalMultimodalProfile, quantization: String, weights: Int64, quality: Double) -> LocalModelDescriptor` that builds a valid, supported descriptor (URL `https://huggingface.co/unsloth/Fixture-GGUF/resolve/<40 hex>/<family>-<quantization>.gguf`, projector in the same repo and revision at 900_000_000 bytes, SHA-256 hex of the id for checksums, `estimatedRuntimeMemory = minimumMemory = recommendedMemory = profile.memory(...)`, `largestTensorBytes 1_000_000_000`, `runtimeBuild`/`minimumLlamaBuild` `LocalVisionRuntime.build`, `parameterBillions profile.parameters`, `activeParameterBillions profile.activeParameters`, context 8192). Fixture manifest (bytes): "Tiny" `qwen35_2B` Q4_K_M 500_000_000 quality 5; "Small" `qwen35_2B` Q4_K_M 1_000_000_000 quality 8; "Mid" `qwen35_4B` Q4_K_M 3e9, Q5_K_M 4e9, Q8_0 6e9 quality 13; "Big" `qwen38_27B` Q4_K_M 16e9, Q5_K_M 17e9 quality 28. Mac: 32 GiB, working set 0.74 × RAM, Metal, 500 GiB disk, `measuredBandwidth` as stated.
  - `testRolesAtTwoHundredGigabytesPerSecond` (bandwidth 200): `recommended` = Mid Q8_0, `faster` = Small (150 tok/s ≥ 1.5 × 25; Tiny is faster but lower quality), `smarter` = Big Q4_K_M (smallest fitting when none is fast); `roles.map(\.role) == [.recommended, .faster, .smarter]`; tags `"recommended"`, `"faster"`, `"smarter, slower replies"`; `allFamilies.map(\.model.familyID) == ["Big", "Mid", "Small", "Tiny"]`.
  - `testNoFasterRoleWhenRecommendedIsAlreadyQuick` (bandwidth 400): `recommended` = Mid Q8_0 (50 tok/s), `faster` nil, `smarter` = Big Q4_K_M.
  - `testNothingFastRecommendsTheBestUsableFamily`: no bandwidth, `performanceCPUCount 1`, `cpuCount 1`, `lowPowerMode true` (prior 14.95 GB/s) → `recommended` = Small, `isFast == false`, its tag `"best available, expect longer waits"`, `faster` and `smarter` nil.
  - `testNothingFitsHasNoRoles`: a 4 GiB Mac → `recommended` nil, `roles` empty, `allFamilies.count == 4`, every one `!fit.canRun`.
  - `testRolesFollowTheGatesOnEveryMac`: the bundled catalogue on Macs of 8, 16, 24, 32, 36, 48, 64, 128, 256 GiB × bandwidths 50, 120, 267, 614, 1_000 → recommended is fast and the highest-quality fast candidate, or (no fast candidate) the highest-quality usable one; faster is nil when recommended ≥ 40 tok/s, otherwise fast, from another family, ≥ 1.5×; smarter is usable, not fast, higher quality; no role has a larger fast package in its family, and a non-fast role has no smaller runnable package; role IDs are unique; every role fits the budget and the disk check.
  - Replace `testWelcomeShowsAtMostThreeSafeUniqueChoicesWithRecommendationFirst` with `testWelcomeShowsTheRolesInOrder` (`WelcomeSetup.choices(recs).map(\.id) == recs.roles.map(\.id)` on the fixture Mac at 200) and rewrite `testWelcomeKeepsChosenModelVisibleAfterRecommendationChanges` against `roles` (preserving Mid Q4_K_M returns Mid Q8_0, Small, Mid Q4_K_M).
  - Delete the tier-only tests `testRequestedHardwareTiersContainExactPackagesAndQuantizations` and `testTopTenAreDeterministicHardwareRankedAndNeverPaddedWithUnsafeModels` (their behavior is removed; `testRolesFollowTheGatesOnEveryMac` replaces them) and rewrite `testSafetyGatesCannotBeOutweighedByQualityAcrossMemoryAndDiskSizes` to check `roles` instead of `tierGroups`.
  - `LocalModelRole` tags: `XCTAssertEqual(LocalModelRole.recommended.tag(isFast: true), "recommended")`, `.recommended.tag(isFast: false) == "best available, expect longer waits"`, `.faster.tag(isFast: true) == "faster"`, `.smarter.tag(isFast: false) == "smarter, slower replies"`.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelSelectionTests`
Expected: build fails (`roles`, `LocalModelRole` not found).

- [ ] **Step 3: Implement** the interfaces and the rules above, then the UI call sites. Build until no reference to the removed names remains (`grep -rn "tierGroups\|rankedChoices\|isResponsive\|LocalModelTiers\|LocalModelWeight\|hardwareOrder" Enigma EnigmaTests` prints nothing outside the two Discover files that Task 7 deletes; adjust those two files only as far as they need to compile).

- [ ] **Step 4: Run the selection, Welcome and Settings suites**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelSelectionTests -only-testing:EnigmaTests/EnigmaWelcomeTests -only-testing:EnigmaTests/EnigmaSettingsTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit** — `git commit -m "Recommend models by role instead of memory tier"`.

---

### Task 6: The seven-family catalogue

**Files:**
- Modify: `Enigma/LocalInference/BundledLocalModels.swift` (rewrite as families)
- Modify: `Enigma/LocalInference/LocalModelManifest.swift` (`LocalModelManifest.bundled` version 5 → 6)
- Create: `scripts/gguf-header.py`, `docs/Updating-the-Model-Catalogue.md`
- Create: `EnigmaTests/LocalModelCatalogueTests.swift`
- Modify: `EnigmaTests/LocalModelSelectionTests.swift`, `EnigmaTests/LocalVisionTests.swift` (catalogue-specific assertions move or update)
- Modify: `Enigma.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  ```swift
  struct LocalModelFamily: Sendable {
    struct Package: Sendable {
      let id: String, quantization: String, file: String
      let byteCount: Int64, sha256: String, largestTensorBytes: Int64
    }
    let name: String
    let publisher: String
    let license: String
    let profile: LocalMultimodalProfile
    let qualityScore: Double
    let summary: String
    let repository: String          // "owner/name"
    let revision: String
    let projectorFile: String
    let projectorByteCount: Int64
    let projectorSHA256: String
    let supportsAudio: Bool
    let packages: [Package]
    var parameters: Double { profile.parameters }
    var activeParameters: Double { profile.activeParameters }
    func url(_ file: String) -> URL      // https://huggingface.co/<repository>/resolve/<revision>/<file>
    var descriptors: [LocalModelDescriptor] { get }
  }
  enum BundledLocalModels {
    static let families: [LocalModelFamily]
    static let models: [LocalModelDescriptor]    // families.flatMap(\.descriptors)
  }
  ```
  Each descriptor: `displayName = name`, `architecture`/`chatTemplate` from the profile, `minimumLlamaBuild` and `runtimeBuild` `LocalVisionRuntime.build`, `estimatedRuntimeMemory = minimumMemory = recommendedMemory = profile.memory(weights:projector:context: 8192)`, `recommendedContextSize 8192`, `performanceClass` as today (`"Vision + Audio model · Text and images in Enigma"` with audio, else `"Vision"`), `parameterBillions = parameters`, `activeParameterBillions = activeParameters`, `modelSummary = summary`, `inferenceProfile = profile`, `advertisedMemoryRange nil`, `modelSupportsAudio = supportsAudio`.

Pinned catalogue (license `Apache-2.0` for all; Qwen publisher `Alibaba / Qwen`, Gemma `Google`; sizes and SHA-256 from the Hugging Face tree API at each revision; largest tensors read from each GGUF header with `scripts/gguf-header.py`):

| Family (profile, quality, audio) | Repository @ revision | Projector file, bytes, SHA-256 |
|---|---|---|
| Qwen3.5 2B (`qwen35_2B`, 8, no) | `unsloth/Qwen3.5-2B-GGUF` @ `f6d5376be1edb4d416d56da11e5397a961aca8ae` | `mmproj-F16.gguf`, 668227264, `7035e9cb8d7c6a9681d07eef9a364783e86ea4cd73faab2eabb4f43a101830c7` |
| Qwen3.5 4B (`qwen35_4B`, 13, no) | `unsloth/Qwen3.5-4B-GGUF` @ `e87f176479d0855a907a41277aca2f8ee7a09523` | `mmproj-F16.gguf`, 672423616, `cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864` |
| Qwen3.5 9B (`qwen35_9B`, 13.5, no) | `unsloth/Qwen3.5-9B-GGUF` @ `3885219b6810b007914f3a7950a8d1b469d598a5` | `mmproj-F16.gguf`, 918166080, `f70dc3509053962b0d0d3ee8a7eacebf5d60aa560cad78254ae8698516ae029f` |
| Gemma 4 12B (`gemma4_12B`, 14, yes) | `unsloth/gemma-4-12b-it-GGUF` @ `fc034cfff751157913579611efad8462ac1be606` | `mmproj-F16.gguf`, 175115840, `91f086971e56d7a7d8d39e271873fccdb49541bd259d6e02c401a4f1cb7a219e` |
| Gemma 4 26B-A4B (`gemma4A4B`, 17, no) | `bartowski/google_gemma-4-26B-A4B-it-GGUF` @ `10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d` | `mmproj-google_gemma-4-26B-A4B-it-f16.gguf`, 1193058528, `41cdabd1e8066e983ee6c288eb0117777376223ee0279cadcd67b2295e4d975f` |
| Qwen3.6 35B-A3B (`qwen36_35BA3B`, 18, no) | `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF` @ `5c2410d71524f4f72b023ce8daf7a80528226d5f` | `mmproj-Qwen_Qwen3.6-35B-A3B-f16.gguf`, 899283296, `67924785ff1885c2b34c15d0e52979e991acca64221694ba2cc3a6474a053fb4` |
| Qwen3.8 27B (`qwen38_27B`, 28, no) | `unsloth/Qwen3.8-27B-GGUF` @ `4ca720788d1e01f1bff70c033e0d0028fd02e502` | `mmproj-F16.gguf`, 927607488, `cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e` |

| Package ID | File | Bytes | SHA-256 | Largest tensor |
|---|---|---|---|---|
| `qwen3.5-2b-q4_k_m` | `Qwen3.5-2B-Q4_K_M.gguf` | 1280835840 | `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223` | 417177600 |
| `qwen3.5-2b-q8_0` | `Qwen3.5-2B-Q8_0.gguf` | 2012012800 | `1b04acba824817554f4ce23639bc8495ff70453b8fcb047900c731521021f2c1` | 540344320 |
| `qwen3.5-4b-q4_k_m` | `Qwen3.5-4B-Q4_K_M.gguf` | 2740937888 | `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4` | 521472000 |
| `qwen3.5-4b-q5_k_m` | `Qwen3.5-4B-Q5_K_M.gguf` | 3143656608 | `8814232b85594dcd46c50e5b8b29324a7efe9e746edbe8a3d1df3d3fce7aad39` | 521472000 |
| `qwen3.5-4b-q8_0` | `Qwen3.5-4B-Q8_0.gguf` | 4482403488 | `10cc391b403021dd11c614679d2fd92f611c3681d29e29651b717316965d61e1` | 675430400 |
| `qwen3.5-9b-q4_k_m` | `Qwen3.5-9B-Q4_K_M.gguf` | 5680522464 | `03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8` | 834355200 |
| `qwen3.5-9b-q5_k_m` | `Qwen3.5-9B-Q5_K_M.gguf` | 6577841376 | `dc2a39aef291f91a9116ad214058da0d86eb648743a124bd8c333787c4b9c91c` | 834355200 |
| `qwen3.5-9b-q8_0` | `Qwen3.5-9B-Q8_0.gguf` | 9527502048 | `809626574d0cb43d4becfa56169980da2bb448f2299270f7be443cb89d0a6ae4` | 1080688640 |
| `gemma-4-12b-q4_k_m` | `gemma-4-12b-it-Q4_K_M.gguf` | 7121861440 | `0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42` | 566231040 |
| `gemma-4-12b-q5_k_m` | `gemma-4-12b-it-Q5_K_M.gguf` | 8413576000 | `32c554c7d1338a23837ae39b3db482213a4a642f96df3b2619f516a2375d16cd` | 692060160 |
| `gemma-4-12b-q8_0` | `gemma-4-12b-it-Q8_0.gguf` | 12669647680 | `f20e7ff1be28c283eeeb18fc895733791c56a5851d5cd3fe9691b7f7d12afa72` | 1069547520 |
| `gemma-4-26b-a4b-q4_k_m` | `google_gemma-4-26B-A4B-it-Q4_K_M.gguf` | 17035039872 | `a07f72221e8e3f77455ab0d7f7652d01a9f63c262b954aa6932a53275a0e895a` | 605552640 |
| `gemma-4-26b-a4b-q5_k_m` | `google_gemma-4-26B-A4B-it-Q5_K_M.gguf` | 19319198848 | `6b4f8074239f72543997a950ff6ae4509553c599f5b432748309ff3438416493` | 605552640 |
| `gemma-4-26b-a4b-q8_0` | `google_gemma-4-26B-A4B-it-Q8_0.gguf` | 26859861120 | `1bb7fdb37fbd542ba972b3eb83ae87752bb9063aff560402e0e2f64235c85226` | 784334848 |
| `qwen3.6-35b-a3b-q4_k_m` | `Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf` | 22285080192 | `b46fedd33e0bfb0cae308aa3c158d0a4b2c4a1d2185a1ed6f093cdaf39064772` | 417177600 |
| `qwen3.6-35b-a3b-q5_k_m` | `Qwen_Qwen3.6-35B-A3B-Q5_K_M.gguf` | 25913185920 | `ec438d1326eb11d8bb94785c54739cd4b60b01ae32bd8532e232a046b19d296d` | 417177600 |
| `qwen3.6-35b-a3b-q8_0` | `Qwen_Qwen3.6-35B-A3B-Q8_0.gguf` | 37812647552 | `bc57de096ec30e45773aa86103f35a8a32cea01f2193a53a3c636d618e4434e9` | 540344320 |
| `qwen3.8-27b-q4_k_m` | `Qwen3.8-27B-UD-Q4_K_M.gguf` | 16464440224 | `322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482` | 1042944000 |
| `qwen3.8-27b-q5_k_m` | `Qwen3.8-27B-UD-Q5_K_M.gguf` | 19771509664 | `2de73110cb254cbf09b54b717578dadff12ef1194e7271527e68202f39ba4bfd` | 1042944000 |
| `qwen3.8-27b-q8_0` | `Qwen3.8-27B-Q8_0.gguf` | 29047086048 | `a680f44a06920e5d689774823782006aa3acc8db95750323373b24139b67e348` | 1350860800 |

Summaries: keep today's for Qwen3.5 4B, Qwen3.5 9B, Gemma 4 12B and Gemma 4 26B-A4B; new: Qwen3.5 2B "A compact model for quick questions and screenshots on smaller Macs.", Qwen3.6 35B-A3B "A large mixture-of-experts model that stays quick on high-memory Macs.", Qwen3.8 27B "The strongest model here, for detailed reasoning on Max and Ultra chips." Quality comments, one per family: "Artificial Analysis Intelligence Index v4.3.2, October 2026" with the value, plus "(estimate)" for Gemma 4 26B-A4B, Gemma 4 12B and Qwen3.5 4B, "34 at xhigh reasoning; 28 at medium" for Qwen3.8 27B, "raised from 11 so the larger model of the line ranks above Qwen3.5 4B" for Qwen3.5 9B, "no index score; placed below Qwen3.5 4B by size (assumption)" for Qwen3.5 2B, and MMMU-Pro where known (Qwen3.5 4B 66.3, Qwen3.5 9B 70.1, Gemma 4 12B 69.1, Gemma 4 26B-A4B 73.8).

- [ ] **Step 1: Write the failing tests** in a new `LocalModelCatalogueTests`. Synthetic Mac helper `mac(memoryGiB: Int, publishedBandwidth: Double)`: `physicalMemory = memoryGiB × gib`, `metalRecommendedWorkingSet = Int64(Double(physicalMemory) × (memoryGiB <= 16 ? 2.0 / 3.0 : 0.74))`, `metalMaximumBufferLength = workingSet × 3 / 4`, `measuredBandwidth = published × 0.87`, 8 performance / 12 CPUs, Metal, unified, Apple Silicon, 500 GiB disk. Owner fixture as in Task 4.
  - `testCatalogueHasSevenFamiliesAndTwentyPackages`: family names in order `["Qwen3.5 2B", "Qwen3.5 4B", "Qwen3.5 9B", "Gemma 4 12B", "Gemma 4 26B-A4B", "Qwen3.6 35B-A3B", "Qwen3.8 27B"]`; `models.count == 20`; `try LocalModelManifest.bundled.validate()`; IDs and checksums unique; `LocalModelManifest.bundled.version == 6`; `LocalVisionModelDescriptor.bundled.count == 20`.
  - `testEveryPackageIsRunnable`: every package passes `LocalModelCompatibility.supports` and `validate()`, has `quantization` in its profile's `quantizations` and in its file name, `activeParameterBillions == profile.activeParameters`, `runtimeBuild == LocalVisionRuntime.build`, `largestTensorBytes < 14_302_248_960`.
  - `testExistingPackagesKeepTheirIDsAndPins`: the six IDs in Global Constraints exist with today's checksums and revisions (copy them from the table above, which matches the current file).
  - `testFamilyMetadataIsConsistent`: within a family every descriptor shares `displayName`, `publisher`, `license`, `revision`, `projector`, `inferenceProfile`, `qualityScore`, `modelSummary`; model and projector URLs share the first five path components; package IDs start with the family's ID stem (`qwen3.5-2b-`, …).
  - `testLargerModelsOfALineRankHigher`: Qwen3.5 2B < 4B < 9B; Gemma 4 12B < 26B-A4B.
  - `testLeftPackagesAreGone`: no ID contains `smolvlm2`, `gemma-4-e4b`, `ministral`, `minicpm`.
  - `testExpectedPicksOnSyntheticMacs` — `(memoryGiB, published) → (recommended, faster, smarter)` IDs:

    | Mac | Recommended | Faster | Smarter |
    |---|---|---|---|
    | (8, 68) | `qwen3.5-2b-q4_k_m` | nil | nil |
    | (16, 120) | `qwen3.5-4b-q5_k_m` | `qwen3.5-2b-q8_0` | `qwen3.5-9b-q4_k_m` |
    | (24, 307) | `gemma-4-12b-q5_k_m` | `qwen3.5-4b-q8_0` | nil |
    | (36, 150) | `gemma-4-26b-a4b-q4_k_m` | `qwen3.5-2b-q8_0` | nil |
    | (64, 460) | `qwen3.6-35b-a3b-q8_0` | nil | `qwen3.8-27b-q4_k_m` |
    | (128, 614) | `qwen3.8-27b-q5_k_m` | `qwen3.6-35b-a3b-q8_0` | nil |

  - `testOwnersMacRecommendsGemma4_12B`: owner fixture → recommended `gemma-4-12b-q5_k_m` at 23.80 tok/s and `isFast`, `fit == .excellent` (10.75 GiB of a 14.21 GiB budget), faster `qwen3.5-4b-q8_0` at 44.67, smarter nil. With the owner's 12B QAT and E4B runs from Task 4 (build 10797) → recommended still `gemma-4-12b-q5_k_m`, now 27.50 tok/s.
  - `testOlderInstalledRecordsDecode`: the JSON of a bundled descriptor without `activeParameterBillions` decodes, validates, keeps its `packageRevision`, and has `resolvedActiveParameterBillions == parameterBillions`.
  - Move or delete the catalogue-specific selection tests that this task invalidates: `testNewCatalogueDoesNotMisrepresentUnavailableRuntimeOrAudio` (MiniCPM-o leaves; keep its audio-label assertions in `testEveryPackageIsRunnable`), `testCatalogPinsEveryQuantizationAndMatchesEmbeddedBuild` (keep its LlamaBridge `Package.swift` check, update count and makers), and in `LocalVisionTests.testLegacyPackageExplainsMigrationWithoutChangingItsFiles` replace the `smolvlm2-2.2b-q8_0` catalogue assertion with "is not in the catalogue". In `LocalVisionTests.testBundledVisionPackagesPinMatchingPairsAndOfficialRuntime` change the count to 20.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelCatalogueTests`
Expected: FAIL (`LocalModelFamily` not found).

- [ ] **Step 3: Implement** `LocalModelFamily` and the seven families from the tables, the comment header "Catalogue reviewed 2026-10-19 — see docs/Updating-the-Model-Catalogue.md", and the manifest version bump. Add the test file to the project.

- [ ] **Step 4: Run the catalogue, estimate, selection and vision suites**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelCatalogueTests -only-testing:EnigmaTests/LocalModelEstimateTests -only-testing:EnigmaTests/LocalModelSelectionTests -only-testing:EnigmaTests/LocalVisionTests`
Expected: `** TEST SUCCEEDED **`. If an expected pick differs, check the Swift formulas against Tasks 1 and 4 before touching the table: the table was computed from them.

- [ ] **Step 5: Add `scripts/gguf-header.py`** (standard library only, executable, run as `python3 -I scripts/gguf-header.py <resolve URL> <file bytes>`). It reads the GGUF v3 header with HTTP `Range` requests in 4 MiB steps, parses metadata and tensor infos, and prints `largestTensorBytes <n> <tensor name>` (tensor size = the next tensor's offset − this offset, the last one ending at file size − aligned data start) and the layout keys `<arch>.block_count`, `attention.head_count_kv`, `attention.key_length`, `attention.value_length`, `attention.sliding_window`, `attention.sliding_window_pattern`, `full_attention_interval`, `nextn_predict_layers`, `expert_count`, `expert_used_count`. Check it: `python3 -I scripts/gguf-header.py https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/gemma-4-12b-it-Q5_K_M.gguf 8413576000` prints `largestTensorBytes 692060160 token_embd.weight`, `gemma4.block_count 48` and `gemma4.attention.sliding_window 1024`.

- [ ] **Step 6: Write `docs/Updating-the-Model-Catalogue.md`**, the release checklist from the spec's section 3: find candidates; confirm the pinned llama.cpp build supports the architecture and projector (text and vision, and whether image tokens use non-causal attention, which needs `--ubatch-size`); pin repository, revision, sizes and SHA-256 (`curl https://huggingface.co/api/models/<repo>/tree/<revision>` gives `lfs.size` and `lfs.oid`); run `scripts/gguf-header.py` for the largest tensor and cache layout; record total and active parameters; set the quality score with its source and the larger-ranks-higher rule; run `LocalModelCatalogueTests`, `LocalModelEstimateTests`, `LocalModelSelectionTests`; do one real install, a screenshot question and **Check performance**; a family that needs a newer llama.cpp bumps `LocalVisionRuntime` in the same release; weights and projector come from one repository and revision; keep package IDs of existing packages. Link it from `docs/README.md` under Guides.

- [ ] **Step 7: Commit** — `git commit -m "Refresh the local model catalogue to seven families"`.

---

### Task 7: One Local models page; Discover removed

**Files:**
- Delete: `Enigma/LocalInference/LocalModelDiscoveryView.swift`, `Enigma/LocalInference/HuggingFaceModelDiscovery.swift`, `Enigma/LocalInference/HuggingFaceModelDownloads.swift`, `EnigmaTests/LocalModelDiscoveryTests.swift`, `EnigmaTests/HuggingFaceModelDownloadsTests.swift` (and their four project entries each)
- Modify: `Enigma/App/SettingsView.swift`, `Enigma/App/ApplicationDelegate.swift` (`settingsRequested` observer at line ~119)
- Modify: `Enigma/LocalInference/LocalModelManagerSection.swift`, `Enigma/LocalInference/LocalModelSettingsLogic.swift`
- Test: `EnigmaTests/EnigmaSettingsTests.swift`, `EnigmaTests/ScreenViewTests.swift` (remove the `discovery:` argument at line ~90)
- Modify: `Enigma.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 3's `detectHardware(remeasureBandwidth:)`, `measuredBandwidth`; Task 5's `roles`, `allFamilies`, `LocalModelRoleChoice.tag`.
- Produces:
  ```swift
  // nested in SettingsView, as today
  enum SettingsDestination: String, CaseIterable, Identifiable { case general, local, cloud, selection
    /// A destination, its raw value, or "discover" (removed; opens .local). Anything else is nil.
    static func requested(_ object: Any?) -> SettingsDestination?
  }
  // SettingsView.init loses `discovery:`, `downloads:` and `sources:`.
  enum LocalModelAction: Equatable, Sendable { case use(isSelected: Bool), update, install }   // .downloadFiles removed
  extension LocalModelSettingsLogic {
    /// ("267 GB/s", "memory bandwidth") or ("Not measured", "memory bandwidth").
    static func bandwidthStat(_ hardware: LocalHardwareProfile) -> (value: String, label: String)
    /// Catalogue packages: "<quantization> · <maker>"; others keep today's legacy/imported subtitles.
    static func installedSubtitle(for model: LocalModel, inCatalogue: Bool) -> String
  }
  ```
  `managerAction` returns `.install` with `isEnabled: false` where it returned `.downloadFiles`. Removed from `LocalModelSettingsLogic`: `compatibilityWarning`, `fitWarning`, `packageAction`, `featuredAction`, `installAction`, `discoverPackages`, `showsDiscoverOperation`; also the descriptor helper `huggingFaceRepositoryID` (it lives in the deleted downloads file). `LocalModelManagerSection` loses `downloads`, `sources` and `downloadListing`.

The page, top to bottom: stats `available for inference`, `free disk`, `chip` and `bandwidthStat`; the hardware-details line; the operation view; the existing "One selected model handles chat…" note and text-only warning; buttons **Check this Mac** (`await advisor.detectHardware(remeasureBandwidth: true)`) and **Check performance**; `EnigmaSectionHeader("For this Mac")` with `EnigmaNote("Picked for this Mac's memory and measured speed. Check performance measures the selected model here.")` and one row per role (badge = tag), or "No suitable model found" with the sheet's explanation when `roles` is empty; `EnigmaSectionHeader("On this Mac")` with one row per installed model (`installedSubtitle`, Use/Selected, Delete), omitted when nothing is installed; `EnigmaDisclosure("All models")` over `allFamilies` with today's `modelRow` (memory warning kept); then Files, **Advanced: Import text GGUF…** and the catalogue hint, unchanged. Gone: **Detect Mac capabilities**, **Refresh recommendations**, every **Download files** button, the download sheet, "Models for other memory sizes", "Imported models" (folded into On this Mac).

- [ ] **Step 1: Write the failing tests** in `EnigmaSettingsTests`. In `Fixture`, give the profile `measuredBandwidth = 267` and pass a counting `measureBandwidth` closure returning 267; drop `discovery`, `sources`, `downloads`.
  - `testDiscoverIsGoneAndItsOldNameOpensLocalModels`: `SettingsDestination.allCases.map(\.rawValue) == ["general", "local", "cloud", "selection"]`; `requested("discover") == .local`; `requested("local") == .local`; `requested(SettingsDestination.cloud) == .cloud`; `requested("not a destination") == nil`; `requested(nil) == nil`. In `testDeepLinksSelectTheRequestedDestination` drop `.discover` from the loop and add: posting `"discover"` shows only "Settings page Local models".
  - `testLocalModelsPageHasOneSetOfChoices`: the Local models page (tall size) shows "For this Mac", "All models", "Check this Mac", "Check performance", `"267 GB/s"` and the recommended package's "Install <name>" marker, and does not show "Detect Mac capabilities", "Refresh recommendations", "Download files", "Lightweight", "Models for other memory sizes".
  - `testCheckThisMacRemeasuresBandwidth`: pressing "Check this Mac" raises the probe count by exactly 1.
  - `testBandwidthStat`: values above for 267.4 (rounds to `"267 GB/s"`) and nil.
  - `testOnThisMacKeepsPackagesThatLeftTheCatalogue`: an installed `LocalModel` with id `gemma-4-12b-it-qat-q4_0-gguf`, display name "Google Gemma 4 12B" and a vision configuration → "On this Mac" shows "Use Google Gemma 4 12B" and "Delete Google Gemma 4 12B" markers; `installedSubtitle(for:inCatalogue: false)` is "Legacy/imported image model · Select to use for all requests".
  - `testInstalledPackageNeedingUpdateCanStillBeUsed`: an installed `gemma-4-12b-q5_k_m` whose `packageRevision` is stale → its For this Mac row shows "Update Gemma 4 12B", its On this Mac row shows "Use Gemma 4 12B".
  - Update `testModelActionsFollowEachModelsState`: drop the `packageAction`/`featuredAction`/`fitWarning` assertions; the over-budget case expects `LocalModelActionState(action: .install, isEnabled: false)` when `!canInstall`, and for a package over the memory budget that `permitsMemoryOverride` (Qwen3.8 27B Q8_0 on `hardware(memory: 32)`) `.install` enabled.
  - Delete `testDiscoverPackagesSkipTheFeaturedModelAndFollowTheSearch`, `testDownloadSheetListsWeightsFirstAndTotalsTheSelection`, `testDownloadFilesOpensTheSheetAndDownloadsTheSelection` and the `settings-download-sheet` snapshot (their features are removed by the spec); delete the two whole suites listed under Files.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/EnigmaSettingsTests`
Expected: build fails (`requested` not found, `.discover` still a case).

- [ ] **Step 3: Implement** the deletions, `SettingsDestination.requested(_:)` (used by `SettingsView.onReceive` and `ApplicationDelegate`), the logic helpers and the page. Keep `docs/design/UI-Style.md` patterns (`EnigmaSectionHeader`, `EnigmaRow`, `EnigmaDisclosure`, mono 11 detail lines). `grep -rn "HuggingFace\|LocalModelDiscovery\|downloadFiles\|huggingFaceRepositoryID" Enigma EnigmaTests` prints nothing.

- [ ] **Step 4: Run the Settings, Welcome, screen-view and selection suites**

Run: `scripts/verify-xcode.sh test -only-testing:EnigmaTests/EnigmaSettingsTests -only-testing:EnigmaTests/EnigmaWelcomeTests -only-testing:EnigmaTests/ScreenViewTests -only-testing:EnigmaTests/LocalModelSelectionTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Refresh the screenshots** — `TEST_RUNNER_ENIGMA_SNAPSHOT_DIR=<a scratch folder> scripts/verify-xcode.sh test -only-testing:EnigmaTests/EnigmaSettingsTests/testSaveSettingsScreenshots -only-testing:EnigmaTests/EnigmaWelcomeTests/testSaveWelcomeScreenshots`, look at `settings-local-*` and the Welcome models step in Paper and Ink, and copy the Paper Local models image over `docs/design/ui-revamp/screenshots/phase-10/settings-local-paper.png`. Delete `docs/design/ui-revamp/screenshots/phase-10/settings-discover-paper.png` and `docs/design/ui-revamp/screenshots/phase-5/settings-download-sheet-paper.png` only if no document other than `docs/Local-Model-Selection.md` and `docs/history/` links them (`grep -rn` first; history keeps its links, so keep the files if history uses them).

- [ ] **Step 6: Commit** — `git commit -m "Put model choice in one Local models page"`.

---

### Task 8: Documentation and release notes

**Files:**
- Modify: `docs/Local-Model-Selection.md` (rewrite), `docs/Welcome-and-Settings.md`, `docs/README.md`, `docs/Testing.md`
- Create: `docs/release-notes/0.11.0.md`

**Interfaces:**
- Consumes: everything above; no code.

- [ ] **Step 1: Rewrite `docs/Local-Model-Selection.md`** keeping its section style: Choosing a model (the three roles and their tags, where they appear); Settings → Local models (the page order from Task 7, Check this Mac, Check performance); the catalogue table (seven families, quantizations, repositories and revisions, what leaves and what is deferred, from the spec's section 5); How picks work (gates, per-family quantization, roles); Memory estimate (the formula, cache layouts, Gemma's 1,024-token image batch and why); Speed estimate (bandwidth test, efficiency, prompt factor, calibration and its applicability, exact measurements); Runtimes (b11734, launch arguments); Privacy (one short section: only catalogue installs contact Hugging Face; the bandwidth test is local); Limitations (estimates not measurements; a runtime bump makes installed packages offer Update); Tests (the suites from this plan and the opt-in probe). Remove the Discover, Downloading files and Discover networking sections.
- [ ] **Step 2: Update `docs/Welcome-and-Settings.md`** (the models step lists roles; Local models section; delete the Discover section) and `docs/README.md` (feature line; link `Updating-the-Model-Catalogue.md` if Task 6 did not). In `docs/Testing.md` add the probe to "Opt-in real-model and CLI checks": `TEST_RUNNER_ENIGMA_BANDWIDTH_PROBE=1 scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalBandwidthProbeTests/testMetalProbeOnThisMac`.
- [ ] **Step 3: Write `docs/release-notes/0.11.0.md`** in the style of `0.10.1.md`: a one-line summary; bullets for bigger recommendations that stay fast (measured bandwidth), the new families and the ones leaving (installed copies keep working under **On this Mac**), one Local models page (Discover and file downloads are gone), **Check this Mac**, and the llama.cpp update with the note that installed models show **Update** once, which downloads the package again.
- [ ] **Step 4: Check the docs** — `grep -rn "Discover\|Download files\|Lightweight\|b10797" docs --include=*.md | grep -v "docs/history\|docs/superpowers"` prints nothing that describes current behavior; no home paths or emails.
- [ ] **Step 5: Commit** — `git commit -m "Document local model recommendations"`.

---

### Task 9: Full verification and real-hardware checks

**Files:** none unless a check fails (then fix in the owning task's files and commit separately).

- [ ] **Step 1: Run the full checks**

Run: `scripts/verify-xcode.sh build`, then `scripts/verify-xcode.sh test`, then `scripts/verify-xcode.sh analyze`.
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`, `** ANALYZE SUCCEEDED **`, with no new analyzer warnings in the files this plan touched.

- [ ] **Step 2: Run the opt-in probe on an Apple Silicon Mac**

Run: `TEST_RUNNER_ENIGMA_BANDWIDTH_PROBE=1 scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalBandwidthProbeTests/testMetalProbeOnThisMac`
Expected: PASS. Note the measured value from the test log (the owner's M5 Pro should read roughly 250–290 GB/s).

- [ ] **Step 3: Real checks from Xcode** (per AGENTS.md: run the app from Xcode with a stable Apple Development signing identity, not the helper's unsigned build, because these checks use Screen Recording). On the owner's 24 GB M5 Pro:
  1. Settings → Local models → **Check this Mac**: the bandwidth stat shows a measured value; **For this Mac** shows Gemma 4 12B (Q5_K_M) tagged recommended and Qwen3.5 4B (Q8_0) tagged faster. Relaunch Enigma: the probe does not run again (the value is unchanged and `hardware.json` keeps it).
  2. Install Gemma 4 12B Q5_K_M. Ask a full-screen screenshot OCR question (a dense page of text). The answer reads text from the whole screen and is not cut short. In the llama-server log there is no `cap image_max_tokens` warning.
  3. **Check performance** on Gemma 4 12B: peak memory ≤ the package's estimate (10.75 GiB, shown under Model details); record tok/s. If the peak is above the estimate, raise the non-causal reserve in `LocalMultimodalProfile.runtimeReserve` to cover it (rounded up to 0.25 GiB), update the Task 1 and Task 6 expectations, and rerun Step 1.
  4. Install Qwen3.5 4B Q8_0; ask a screenshot question; **Check performance**. Peak ≤ its estimate (6.55 GiB).
  5. The installed Gemma 4 12B QAT (if still present) appears under **On this Mac** and answers a question.
  6. Run `scripts/verify-xcode.sh test -only-testing:EnigmaTests/ScreenNativeSmokeTests` with `/tmp/AI-Spotlight-Vision-Smoke.json` pointing at the new Gemma 4 12B install (docs/Screen-Skill.md) and confirm it passes.

- [ ] **Step 4: Report** the measured bandwidth, the two peaks and tok/s, and any check that could not be run, in the final summary. Leave the branch for the owner to merge; do not publish to `main` from this plan.

---

## Self-review

- **Spec coverage.** §1 bandwidth → Task 3; estimates, calibration, applicability → Task 4; roles → Task 5. §2 page → Task 7; Welcome and ⌘K → Task 5; removals and the destination redirect → Task 7. §3 families, IDs, `activeParameterBillions`, largest tensor, floors removed, runnable-only test, quantizations, quality → Tasks 1, 4, 6; checklist doc → Task 6. §4 memory → Task 1. §5 contents and expected picks → Task 6 (with the refinements above). §6 runtime → Task 2, real checks → Task 9. Failure handling → Tasks 3 (probe), 4 (old benchmarks), 7 (installed packages, memory warning), 5 (`fasterAlternative`). Testing and Docs sections → Tasks 1–8.
- **Step scan.** Every code step names its signatures and values; bodies appear only for the probe arithmetic, the calibration rules and the role algorithm, which the signatures do not determine.
- **Type consistency.** `cacheLayout.bytes(context:physicalBatch:)`, `physicalBatchSize`, `imageMaxTokens`, `runtimeReserve`, `activeParameters`, `isMixtureOfExperts` (Task 1) are used under those names in Tasks 2, 4 and 6; `detectHardware(remeasureBandwidth:)` (Task 3) in Task 7; `estimate`, `isFast`, `isUsable` (Task 4) in Tasks 5–6; `roles`, `allFamilies`, `LocalModelRoleChoice.tag` (Task 5) in Task 7.
- **Review Focus.** Each of the five lines has its test in the owning task.
- **Proportion.** The plan is long mainly because of the pinned tables; code blocks are signatures and assertions only.
