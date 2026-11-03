# CP2: Local windows

Read [agent-workflow.md](agent-workflow.md), the F35 entry, the plan, and the
Hand-offs of CP0–CP1.

## Goal

Each local model runs at the largest of 8K, 16K or 32K that its trained
maximum and this Mac's memory allow (F15, folded into F35). It's a runtime
choice, not a package change: it reaches llama-server's `--ctx-size`, the
embedded engine and `LocalModel.contextWindow`, and never trips the
manifest's Update check. Benchmarks record the size they ran at. An optional
override sits under **Settings → On this Mac → › Advanced**.

## Starting point

- **Catalogue** (Swift, no JSON): `BundledLocalModels.families` →
  `LocalModelFamily.descriptors` (`BundledLocalModels.swift`) sets
  `recommendedContextSize: 8192` for every package and bakes memory
  estimates at context 8192 via `profile.memory(weights:projector:context:)`.
  `LocalModelManifest.bundled` is `version: 8`. Remote catalogue signing
  (`LocalCatalogUpdates.swift`) exists but isn't configured (no Info.plist
  keys), so the bundled catalogue is the only live source; new fields must
  still be optional so old payloads and installed descriptors decode.
- **No trained-maximum field** exists in Swift. The embedded engine's C++
  bridge already clamps to `llama_model_n_ctx_train`
  (`Packages/LlamaBridge/.../AISLlamaBridge.cpp`). `scripts/gguf-header.py`
  doesn't read `context_length`; `scripts/add-catalogue-model.py` doesn't
  print it.
- **Where the window flows:**
  - Install writes `LocalVisionConfiguration.contextWindow` from
    `recommendedContextSize` (`LocalModelManifest.swift`; struct in
    `Enigma/Screen/ScreenRoutingPolicy.swift`).
  - `LocalModel.contextWindow` (`LocalModelEngine.swift`): vision
    configuration, else `recommendedContextSize`, else 4,096.
  - `LocalFileRuntime.contextWindow(for:)` (`Enigma/Files/LocalFileInference.swift`):
    the vision value unclamped, else 4,096–16,384 clamp; `textArguments`
    passes it as `--ctx-size`; `validateBudget` requires 4,096–32,768.
  - `LlamaServerVisionEngine`: validation requires 4,096–32,768;
    `arguments(...)` passes `--ctx-size config.contextWindow`; a test hook
    `fileContextOverride`; exact token checks against
    `fileContextOverride ?? LocalFileRuntime.contextWindow(for:)`.
  - `LlamaCPPModelEngine`: `contextSize ?? installedModel.contextWindow` →
    `AISLlamaEngineCreate`.
  - Budgets read `model.contextWindow` (`LocalModelEngine.prepare`,
    `LlamaServerVisionEngine.preparationBudget`, `LocalToolAgent.prepare`,
    `AutoRouter`).
- **Update check:** `LocalModelDescriptor.requiresUpdate(_:)` is true when,
  among others, `installed.visionConfiguration?.contextWindow != recommendedContextSize`.
  So the runtime size must not be written into `visionConfiguration`.
- **Memory:** `LocalCacheLayout.bytes(context:physicalBatch:)` and
  `LocalMultimodalProfile.memory(weights:projector:context:)`
  (`LocalMultimodalProfile.swift`); `LocalModelSelector.assess`
  (`LocalModelSelection.swift`) checks `runtimeMemory` against
  `hardware.inferenceMemoryBudget` (`LocalHardwareProfile.swift`), with
  "comfortable" at ≤ 4/5 of it.
- **Benchmarks:** `LocalModelAdvisor.record` stores
  `contextSize: descriptor?.recommendedContextSize ?? 4_096`, not the runtime
  size. `LocalModelSelector.assess` matches benchmarks by
  `contextSize == model.recommendedContextSize`. `LocalModelAdvisor.latestBenchmark(for:)`
  ignores context size. `LocalModelManagerSection.swift` shows
  "… \(recommendedContextSize) token context …".
- **Settings:** the Advanced toggle and "On this Mac" page came with F14
  (`Enigma/LocalInference/LocalModelManagerSection.swift`, `SettingsView.swift`);
  follow `docs/design/UI-Style.md` and reuse `EnigmaControls.swift`.
- Tests: `LocalModelCatalogueTests`, `LocalModelEstimateTests`,
  `LocalModelSelectionTests` (it already edits `recommendedContextSize` in
  three places, around the Update test), `LocalVisionTests`,
  `EnigmaSettingsTests`; `python3 -I -B -m unittest discover -s scripts/tests`
  if a script changes.

## Interfaces

**Produces:**

```swift
// LocalModelDescriptor (optional, so old payloads decode)
var trainedContextLength: Int? = nil

// Enigma/LocalInference/LocalContextWindow.swift
enum LocalContextWindowPreference: String, CaseIterable, Sendable {   // saved in UserDefaults
  case smaller, automatic, larger, maximum   // 4K, auto, 16K, 32K
}
enum LocalContextWindowChoice {
  static let sizes = [8_192, 16_384, 32_768]
  /// The largest size ≤ trained maximum (8,192 when unknown) whose memory estimate fits
  /// `hardware.inferenceMemoryBudget`, never below 8,192 for catalogue models.
  static func automatic(for descriptor: LocalModelDescriptor, hardware: LocalHardwareProfile) -> Int
  /// The size the runtime uses for this preference; nil for a preference the model or memory
  /// rules out (the settings row disables it).
  static func size(for preference: LocalContextWindowPreference, model: LocalModel,
                   hardware: LocalHardwareProfile) -> Int?
  /// The preference's size may not fit comfortably: the warning shows before applying it.
  static func needsWarning(...) -> Bool
}

// LocalModel
var contextWindow: Int   // now the runtime choice; the package value stays recommendedContextSize
```

## Decisions this plan fixes

- **Trained maximum** comes from each catalogue package's GGUF
  `<arch>.context_length`, added to `gguf-header.py`'s output and to every
  bundled descriptor. Bump the bundled manifest version. Imported models with
  no descriptor keep 4,096 (the embedded engine's bridge still clamps to the
  real trained maximum).
- **Fit test:** `profile.memory(weights:projector:context: size)` ≤
  `hardware.inferenceMemoryBudget` × 4/5 (the "comfortable" line), so a
  larger window never makes a recommended model uncomfortable.
- **Presets** (labels exact): `Smaller (4K)`, `Automatic`, `Larger (16K)`,
  `Max (32K)`. The row is titled `Context size`, with the detail
  `Larger sizes remember more of a long chat but use more memory and answer a little slower.`
  A preset the model's trained maximum rules out is disabled. A preset whose
  memory estimate is over the comfortable line asks before applying:
  `This size may not fit in this Mac's memory alongside other apps. Use it anyway?`
  with `Use It` and `Cancel`.
- **Applying** a new size restarts the local runtime at the next request (the
  same path an idle unload takes); nothing is downloaded.
- **Benchmarks** record the runtime size; matching uses it. A benchmark at
  another size doesn't count as measured for this one, so the model shows its
  estimate and a new performance check runs as it does for a new install.
- **Manifest:** `requiresUpdate` keeps comparing `visionConfiguration.contextWindow`
  with `recommendedContextSize`; the runtime size is never written there.

## Tasks

### Task 2.1: Trained maximum

- [ ] **Failing tests:** `testEveryBundledPackageHasTrainedContextLength`
  (and it's ≥ 8,192); `testDescriptorDecodesWithoutTrainedContextLength`;
  the script test for `context_length` in `scripts/tests`.
- [ ] Read each package's value with the script (no download beyond the
  GGUF header ranges the script already fetches) and add it.

### Task 2.2: The choice

- [ ] **Failing tests** (`LocalModelEstimateTests`):
  `testAutomaticPicksLargestThatFitsMemory` (8 GB, 16 GB, 36 GB, 64 GB Macs,
  a small and a large model); `testAutomaticRespectsTrainedMaximum`;
  `testAutomaticNeverBelow8KForCatalogueModels`; `testPresetsDisabledByTrainedMaximum`;
  `testWarningWhenPresetIsOverComfortableMemory`.

### Task 2.3: Runtime plumbing

- [ ] **Failing tests:** `testServerGetsChosenCtxSize` (llama-server
  arguments); `testFileModeUsesChosenWindow` (no 16,384 clamp below 32K);
  `testEmbeddedEngineGetsChosenWindow`; `testBudgetsUseChosenWindow`
  (`LocalToolAgent.prepare`, `preparationBudget`, Auto);
  `testChosenWindowDoesNotRequireUpdate`; `testChangingPreferenceReloadsRuntime`.
- [ ] Keep the 4,096–32,768 validation ranges.

### Task 2.4: Benchmarks by size

- [ ] **Failing tests** (`LocalModelSelectionTests`): `testRecordSavesRuntimeSize`;
  `testBenchmarkAtOtherSizeIsNotMeasured`; `testLatestBenchmarkMatchesSize`;
  the manager row shows the runtime size.

### Task 2.5: The Advanced override

- [ ] **Failing tests** (`EnigmaSettingsTests`): the row shows only with
  Advanced on; its four presets with labels and VoiceOver labels; disabled
  presets; the warning and both buttons; the choice persists in an injected
  defaults suite; the page still renders at window size in Paper and Ink.

### Task 2.6: Docs

- [ ] `docs/Local-Model-Selection.md`: the automatic window, the trained
  maximum, benchmarks by size, the Advanced override.
  `docs/Updating-the-Model-Catalogue.md`: the new field and where it comes
  from. `docs/Chat.md` → "Context budgets": local windows.

## Exit checks

- The classes above pass; full `build`, `test`, `analyze`; script tests if
  a script changed.
- With the owner's approval, one live check per installed catalogue model:
  the server starts at the chosen size and answers.

## Hand-off

_To be filled in by the CP2 worker._
