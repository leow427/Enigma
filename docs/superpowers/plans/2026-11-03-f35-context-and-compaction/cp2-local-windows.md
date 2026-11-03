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

1. **Summary:** each catalogue model now runs at the largest of 8K, 16K or
   32K that its trained maximum and this Mac's memory allow, within 4/5 of the
   inference budget, or at the size picked under **Settings → On this Mac →
   › Advanced → Context size**. The size is set on `LocalModel` as the
   library loads it (`runtimeContextWindow`) and reaches llama-server's
   `--ctx-size`, the embedded engine, File Mode and every budget, never the
   installed `visionConfiguration`, so Update isn't offered. Benchmarks record
   and match the size they ran at. Every bundled package carries its GGUF
   `context_length`.
2. **Files:**
   - `Enigma/LocalInference/LocalContextWindow.swift` (new):
     `LocalContextWindowPreference`, `LocalContextWindowChoice`.
   - `Enigma/LocalInference/LocalModelManifest.swift`: `trainedContextLength`
     (optional, validated), bundled manifest version 9.
     `BundledLocalModels.swift`: `LocalModelFamily.trainedContextLength`, set
     for all 14 families.
   - `LocalModelEngine.swift`: `LocalModel.runtimeContextWindow`,
     `packageContextWindow`; `contextWindow` is the runtime one.
     `LocalModelInstallationStore.swift`: a `contextWindow:` resolver
     (default `LocalContextWindowChoice.current`) sets it on every model it
     returns.
   - `LlamaServerVisionEngine.swift`: `--ctx-size` and validation use
     `model.contextWindow`. `LocalFileInference.swift`: File Mode uses the
     runtime size (no 16,384 clamp). `LlamaCPPModelEngine.swift`:
     `requestedContext(_:model:)`, and the engine loads again when the size
     changes.
   - `LocalModelAdvisor.swift`, `LocalModelSelection.swift`: benchmarks record
     `model.contextWindow`; `latestBenchmark`, `assess(…contextSize:)` and
     `select(…contextSizes:)` match it.
   - `LocalModelSettingsLogic.swift`: `contextDetail(for:installed:runtimeSize:)`.
     `LocalModelManagerSection.swift`: Model details show the runtime size; a
     `SettingsAdvanced` with `LocalContextSizeRow`.
   - `EnigmaControls.swift`: `EnigmaOption.accessibilityLabel`, read by
     `EnigmaSegmentedControl`'s VoiceOver picker; a segment's test marker now
     sits inside its `.disabled`, so it reports the option's state.
     `SettingsView.swift`: "context size" finds On this Mac.
   - `scripts/gguf-header.py` prints `context_length`;
     `scripts/add-catalogue-model.py` prints `trainedContextLength` and stops
     without it.
   - Tests: `LocalModelCatalogueTests`, `LocalModelEstimateTests` (new class
     `LocalContextWindowTests`), `LocalVisionTests`, `LocalModelSelectionTests`,
     `EnigmaSettingsTests`, `scripts/tests/test_add_catalogue_model.py`.
   - Docs: `docs/Local-Model-Selection.md` (Context size, benchmarks by size,
     catalogue version), `docs/Updating-the-Model-Catalogue.md`,
     `docs/Chat.md` (local budgets), the plan's Interface map.
3. **Decisions:**
   - **The trained maximum is per family** (`LocalModelFamily.trainedContextLength`),
     read from each family's first package with `gguf-header.py` on
     2026-11-03: Gemma 4 E4B 131,072, every other family 262,144. All are
     above 32K, so today only memory limits the choice.
   - **Installed records are snapshots** of the descriptor they were installed
     with, so one saved before the field reads the bundled catalogue's package
     with the same ID and checksum; unknown is 8,192.
   - **Where the size is set:** the installation store, the one place models
     are loaded, through an injected resolver. The app's resolver reads the
     preference from standard defaults and this Mac's memory (detected once);
     under the test host it is inert, so tests never depend on the
     developer's Mac or saved choice.
   - **Smaller (4K) is 4,096,** below the 8K floor Automatic keeps; the
     server's 4,096–32,768 range still applies. It is disabled for vision
     packages (owner, 2026-11-03), since a screenshot's image tokens don't fit,
     so today it only applies to text-only packages. A saved preset that a
     model rules out runs that model at Automatic.
   - **The preset is global, Use It is per model** (`localContextWindowAccepted`,
     `id=preset` lines). A model selected later that the preset puts over its
     comfortable line runs at Automatic until its warning is answered Use It;
     the row shows the warning again, and Cancel there sets the preset back
     to Automatic.
   - **A new size gets Check performance** when the selected model has no
     benchmark at it, so recommendations and speeds are measured, not
     guessed.
   - **Disabled vs. warned:** a preset over the whole inference budget, or
     above the trained maximum, is disabled; one over the comfortable line
     asks first, but only when it is larger than Automatic's size (a model
     over the line already at 8K doesn't warn for 4K).
   - **The warning is inline** in the row (status line, **Use It**,
     **Cancel**), like the page's other memory warnings, not a modal alert;
     VoiceOver announces it. The row is disabled until this Mac's memory is
     known and while the model is busy.
   - **Applying** saves the preference and refreshes the view model's
     installed model; the server starts again at the next request because
     its loaded model no longer equals the selected one, and the embedded
     engine because its size differs.
   - **Recommendations** match benchmarks at an installed package's runtime
     size; a package not installed has no benchmarks, so it keeps the
     package's size.
   - **Imported models** keep their own window, and every preset but
     Automatic is disabled for them.
4. **Verification:**
   - New tests: `LocalContextWindowTests` (Automatic by memory and trained
     maximum, the 8K floor, presets ruled out, Smaller only for text
     packages, the warning line, unanswered warnings run at Automatic, the
     labels); in `LocalModelCatalogueTests`, every package's trained length,
     decoding without it, and one below the recommended size rejected; in
     `LocalVisionTests`, `--ctx-size`, File Mode, the embedded engine and the
     budgets use the chosen size, it never trips Update, and a changed
     preference reloads the runtime; in `LocalModelSelectionTests`, benchmarks
     record and match the size; in `EnigmaSettingsTests`, the row under
     Advanced, disabled presets, the warning's Use It and Cancel, asking again
     for a model not yet answered (Cancel and Use It), the ruled-out note and
     rendering in Paper and Ink; `scripts/tests/test_add_catalogue_model.py`.
   - Two review rounds (round 1: 5 Should fix; round 2: 4 Should fix, no
     Blockers). Round 2's fixes were small and tested here, without a third
     round.
   - Exit checks: the six affected classes (198 tests) pass; the full
     `verify-xcode.sh build` and `analyze` pass; the full `test` run (2,279
     tests) fails only `AppCommandTests`' two window-layout tests, which fail
     on main on this Mac too, plus a routing test broken by the 256K cloud
     change, fixed in its own commit.
   - Live check per installed catalogue model (owner approved, 2026-11-03;
     `F35LiveTests.testEachInstalledModelStartsAtItsChosenSizeAndAnswers`), on
     a 24 GB Mac (15,255 MB inference budget), preset Automatic: Bonsai 2 27B
     Q2_0 at 32,768 (12,013 MB estimate), Gemma 4 12B Q5_K_M at 32,768
     (11,944 MB) and Qwen 3.8 27B IQ3_XXS at 8,192 (14,043 MB, over the
     comfortable line already at 8K). Each server started with that
     `--ctx-size` and answered.
5. **Limitations:**
   - The memory estimates at 16K and 32K come from the cache layouts, not
     measured peaks at those sizes.
   - The fit check at load (`LocalModelSelector.assess` in
     `LlamaServerVisionEngine.load`) still uses the package's 8K estimate.
   - Settings shows the size chosen for the selected model; another installed
     model's row shows its own.
   - Benchmarks recorded before CP2 ran at 8,192, so on a Mac where Automatic
     is now 16K or 32K they no longer match: the measured speed falls back to
     an estimate until **Check performance** runs again. Nothing runs it on
     its own (it would load the model unasked).
   - The resolver reads this Mac's memory once per launch; **Check this Mac**
     updates Settings, but the runtime keeps the launch-time figure.
6. **For the next checkpoint:** `LocalModel.contextWindow` is the runtime
   size everywhere, so CP3–CP5 read it as before;
   `LocalModel.packageContextWindow` is the package's.
