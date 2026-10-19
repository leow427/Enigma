# Local model recommendations — design

Status: approved design, not yet implemented. Date: 2026-10-19.

## Goal and users

Enigma is a low-latency, privacy-first app for quick questions. Its local
models should be the strongest ones a Mac runs *well*, offered in one obvious
place. Today they are not:

- On a 24 GB M5 Pro, a fresh install recommends **Qwen3.5 4B**, offers
  **Qwen3.5 9B** as "smarter" (flagged slow), and blocks every 12B and 14B
  package. The same Mac measured a Gemma 4 12B at 33 tok/s with a 9.2 GB peak.
- Model choice is spread over four places (Welcome, the ⌘K sheet, Settings →
  Local models, Settings → Discover), and Discover mostly lists models Enigma
  cannot run.
- The catalogue was reviewed on 2026-09-10, keeps two families that newer
  models outscore (Ministral 3), one that cannot be installed (MiniCPM-o 4.5),
  and nothing for Macs above 32 GB.

Success: on that Mac, a 12B-class model is **Recommended** (Gemma 4 12B with
the October 2026 quality scores); every picker shows the
same three choices; Discover and the Hugging Face browser are gone; the
catalogue holds current models from 8 GB to 128 GB Macs; and a later model
refresh is an ordinary release that follows a short checklist.

## Why the current picks are too small

Measured against the saved hardware report of the 24 GB M5 Pro
(`physicalMemory` 24 GiB, Metal recommended working set 17.76 GiB, 6
performance cores):

1. **The memory estimate is too high.** `LocalMultimodalProfile.memory` is
   1.2 × (weights + projector) + a full F16 KV cache on every layer at 8,192
   tokens + 2 GiB. Gemma 4 12B Q5_K_M comes to 14.22 GiB against a budget of
   14.21 GiB (`min(60% RAM, RAM − reserve, 80% Metal working set)`), so it is
   rejected by about 10 MB. Ministral 3 14B Q5_K_M comes to 14.99 GiB.
2. **The speed estimate is far too low.** `LocalModelSelector.prediction`
   treats `18 + 5 × performance cores` (capped at 100) as bandwidth: 48 on this
   Mac, whose published bandwidth is 307 GB/s. It predicts 6.1 tok/s for Gemma
   4 12B Q5_K_M and 7.8 tok/s for Qwen3.5 9B, both under the 8 tok/s bar.
   Measured runs on this Mac: Gemma 4 12B QAT Q4_0 at 33.2 tok/s (predicted
   14.8), Gemma 4 E4B QAT Q4_0 at 67.2 tok/s (predicted 10.0). Calibration from
   a measurement is capped at 2× the guess, and exact measurements count only
   for the exact checksum, so those runs stopped counting when the catalogue
   changed packages.
3. **Tiers are three hard-coded RAM buckets** (`LocalModelTiers`: under 24,
   24–32, 32 GB and up) with hand-picked lists. A 128 GB Mac gets the 32 GB
   list. MiniCPM-o 4.5 holds a slot in every tier.

## Decisions

1. **"Best for this Mac" means the smartest model that stays fast.** A model is
   *fast* at an estimated ≥ 20 tok/s and a first token within 2 s on a
   256-token prompt. Speed is a gate, like memory; quality ranks only what
   passes.
2. **Discover is removed and folded into Local models.** The Hugging Face
   browser and file downloader go with it. Enigma contacts `huggingface.co` only
   to install a catalogue package.
3. **New models ship with app releases.** The catalogue stays in code; a
   refresh is a normal Sparkle release. The unconfigured signed-catalogue
   updater (`LocalCatalogUpdater`) is left as it is.
4. **Speed comes from measured memory bandwidth (approach A).** A short Metal
   copy test measures this Mac's bandwidth; benchmarks recalibrate it.
   - Rejected, B — GPU core count from IOKit mapped to a bandwidth class: a
     table in disguise; bandwidth per core differs by chip generation.
   - Rejected, C — chip-name table: needs an update for every chip, and the
     project deliberately avoids chip names.
5. **The catalogue is refreshed to seven families** (section 5), and the
   100B-class models are deferred to a later refresh.
6. **The llama.cpp runtime moves to a current build** (b11734 at the time of
   writing): b10797 garbles Gemma 4 screenshot OCR, and newer builds add faster
   Metal kernels.

## Design

### 1. How Enigma picks a model

**This Mac.** `LocalHardwareProfile` gains `measuredBandwidth: Double?`
(GB/s).

- Measured by a Metal copy test: a few short passes streaming ~1 GiB through
  the GPU, keeping the best pass, clamped to 50–1,500 GB/s, well under a
  quarter of a second in total. It runs off the main thread.
- Runs once per hardware fingerprint and Low Power Mode state, is saved in
  `hardware.json`, and re-runs on **Check this Mac**. It does not run at every
  launch.
- Not part of `fingerprint`, so run-to-run variation never invalidates
  benchmarks.
- If Metal is missing or the test fails, `measuredBandwidth` is nil and the
  current core-count prior (with its 35% Low Power Mode reduction) is used.

**Estimates for each package.**

- **Decode tok/s** = bandwidth × efficiency ÷ active weight bytes.
  - Active weight bytes = file size × active ÷ total parameters. Dense models
    use the file size; mixture-of-experts models use their active experts, and
    Gemma E-models their effective parameters.
  - Starting efficiency, relative to the measured bandwidth: 0.75 for dense
    models and 0.45 for mixture-of-experts models, from published llama.cpp
    Apple Silicon results (discussion #4167 and later runs). MoE routing reads
    memory less efficiently, so its constant is lower.
  - The latest applicable benchmark on this Mac replaces the constant for its
    kind (dense or MoE): efficiency = measured tok/s × the measured package's
    active bytes ÷ bandwidth. Any architecture counts; the same architecture
    is preferred. The 2× cap is removed.
- **Prompt tok/s** starts at 1.3 × bandwidth × 7 ÷ active parameters
  (billions), the conservative end of published results for M1–M4. Active,
  not total, parameters, because prompt processing also runs only the active
  experts; with total parameters every MoE model would fail the first-token
  gate. Newer chips are underestimated until measured. The latest applicable
  benchmark recalibrates the factor the same way.
- **Time to first token** keeps today's formula: 256 ÷ prompt tok/s +
  1 ÷ decode tok/s.
- An exact measurement of the package still overrides both estimates.
- Applicability: exact measurements keep today's rules (hardware fingerprint,
  power mode, runtime build, 90 days). Efficiency calibration uses the same
  rules **without** the runtime build, because efficiency belongs to the Mac,
  so measurements survive a runtime bump.

**Three roles replace weight classes and RAM tiers.** `LocalModelTiers`,
`LocalModelWeight` and `tierGroups` are removed. Each catalogue *family* is one
candidate; its quantization is the highest precision that passes both gates,
or, when none is fast, the smallest that fits.

- **Gates:** fits the memory budget (`inferenceMemoryBudget`, unchanged), and
  is fast.
- **Recommended:** the highest-quality family that passes both gates.
- **Faster:** the highest-quality family at least 1.5× quicker than
  Recommended, offered only while Recommended is under 40 tok/s. Above that,
  Recommended already feels instant and a smaller model adds nothing.
- **Smarter, slower:** the highest-quality family above Recommended that fits
  but misses the speed bar, while still ≥ 8 tok/s.
- **Nothing fast:** the best usable family (≥ 8 tok/s) is Recommended, labelled
  "best available, expect longer waits", as today.
- **Nothing fits:** the existing "No suitable model found" message.

`LocalModelRecommendations` keeps `assessments`, `recommended`, `faster`,
`smarter` and `fasterAlternative(to:)`. `rankedChoices`, `otherAssessments`,
`tierGroups` and `otherTierAssessments` are replaced by `roles` (the non-nil
Recommended, Faster and Smarter, in that order) and `allFamilies`.

### 2. One place to choose a model

**Settings → Local models**, top to bottom:

1. This Mac: memory for inference, free disk, chip, and measured bandwidth.
   Buttons: **Check this Mac** (replaces **Detect Mac capabilities** and
   **Refresh recommendations**) and **Check performance**.
2. **For this Mac**: up to three rows tagged **recommended**, **faster** and
   **smarter, slower replies**, each with fit, estimated or measured speed,
   download size and Install / Update / Use / Selected. Empty roles are
   omitted.
3. **On this Mac**: every installed model, catalogue or imported, with Use and
   Delete.
4. **All models** (collapsed): every catalogue family with its fit here.
   Over-budget installs keep the memory warning.
5. **Files** and **Advanced: Import text GGUF…**, unchanged.

Gone from the page: weight-class sections, "Models for other memory sizes",
MiniCPM-o rows and every **Download files** button.

**Welcome setup** (`WelcomeSetup.choices`) and the **⌘K "Find a model for this
Mac" sheet** show the same roles in the same order, so all pickers agree. The
sheet's "Lightweight, middleweight and heavyweight…" hint goes.

**Removed:** `SettingsDestination.discover`; `LocalModelDiscoveryView.swift`,
`HuggingFaceModelDiscovery.swift`, `HuggingFaceModelDownloads.swift`;
`LocalModelDiscoveryTests` and `HuggingFaceModelDownloadsTests`; the featured
model and Discover helpers in `LocalModelSettingsLogic`; the Discover parts of
`SettingsView`, `EnigmaSettingsTests` and `ScreenViewTests`; any descriptor
helper used only by **Download files**. A `.settingsDestinationRequested` for a
removed destination opens Local models.

### 3. Catalogue structure and freshness

- `BundledLocalModels` becomes a list of **families**. A family holds the
  shared facts once (name, publisher, license, `LocalMultimodalProfile`, total
  and active parameters, quality score with its source, summary, repository,
  revision, projector) and its quantizations, each with its exact size,
  SHA-256 and largest tensor size. It expands into the existing
  `LocalModelDescriptor`s, so install, verification and runtime code is
  unchanged.
- Package IDs stay the same where a package already exists
  (`qwen3.5-4b-q4_k_m`, `qwen3.5-4b-q5_k_m`, `qwen3.5-4b-q8_0`,
  `qwen3.5-9b-q5_k_m`, `gemma-4-12b-q5_k_m`, `gemma-4-26b-a4b-q4_k_m`), so
  installed records and benchmarks carry over. New packages follow the same
  `<family>-<quantization>` pattern.
- A new optional descriptor field, `activeParameterBillions`, defaults to
  `parameterBillions` when absent, so older installed records still decode.
- `largestTensorBytes` is read from each GGUF's header when the package is
  pinned, replacing the 1 GiB / 3 GiB constants, so the Metal buffer check
  stays correct for the larger models.
- The tier floors (`minimumGiB` 16, 24 and 32) are removed; a package's
  minimum memory is its estimate.
- Only runnable packages are listed. A test asserts every package passes
  `LocalModelCompatibility.supports`. `LocalMultimodalProfile.quantizations`
  matches what the catalogue ships (Gemma 4 gains Q8_0).
- **Quality score.** Each family's `qualityScore` is the Artificial Analysis
  Intelligence Index (v4.3.2 snapshot, October 2026), checked against MMMU-Pro
  for vision. Within one model line, a larger model of the same generation
  never scores below a smaller one; this corrects the index's current
  estimate that ranks Qwen3.5 4B above Qwen3.5 9B. A comment cites the source
  and date for each score.
- `docs/Updating-the-Model-Catalogue.md` is the release checklist: find
  candidates; confirm the pinned llama.cpp build supports text and vision;
  pin revision, sizes, SHA-256 and largest tensor; record cache layout and
  active parameters; set the quality score with its source; run the catalogue
  tests; do one real install, a screenshot question and **Check performance**.
  A family that needs a newer llama.cpp bumps `LocalVisionRuntime` in the same
  release.

### 4. Memory estimate

`LocalMultimodalProfile.memory` becomes:

> weights + projector + KV cache + 1.5 GiB runtime reserve

- **Weights and projector count once.** llama.cpp maps the file and Metal
  wraps the mapping without copying, so the 1.2× factor goes.
- **KV cache (F16).** Full-attention layers reserve the whole 8,192 tokens.
  Sliding-window layers reserve their window plus 512 tokens, rounded up to
  256 (llama.cpp's default, without `--swa-full`). Hybrid Qwen models
  (3.5, 3.6, 3.8) reserve cache only for their attention layers; their small
  recurrent state is inside the reserve. Each profile records its layer
  counts, KV heads, head dimensions and window instead of today's single
  `cacheBytesPerToken`.
- **Runtime reserve, 1.5 GiB:** the compute buffer (about 0.5 GB at the
  default batch), encoding one image of up to 4,096 tokens, and the server.
  Set from the recorded peaks on the 24 GB M5 Pro:

| Package | New estimate | Measured peak |
|---|---|---|
| Gemma 4 12B QAT Q4_0 | 8.76 GiB | 8.57 GiB |
| Gemma 4 E4B QAT Q4_0 | 7.54 GiB | 6.64 GiB |

- Gemma 4 12B Q5_K_M drops from 14.22 GiB to about 10.1 GiB, inside that Mac's
  14.2 GiB budget. The budget formula is unchanged.
- If the runtime bump's batch settings (section 6) enlarge the compute buffer,
  the reserve grows to match, and the peak check in section 6 confirms it.

### 5. Catalogue contents

Seven families. Quantizations are Q4_K_M, Q5_K_M and Q8_0 unless noted.
Repositories and revisions are pinned during implementation; existing packages
keep their current pins, and the weights and projector always come from the
same repository and revision.

| Family | Parameters (active) | llama.cpp arch | License | Mainly for | Status |
|---|---|---|---|---|---|
| Qwen3.5 2B (Q4_K_M, Q8_0) | 2B | qwen35 | Apache-2.0 | 8 GB Macs | new; replaces SmolVLM2 2.2B |
| Qwen3.5 4B | 4.7B | qwen35 | Apache-2.0 | the Faster pick | kept |
| Qwen3.5 9B | 9.7B | qwen35 | Apache-2.0 | 16 GB Macs | kept; adds Q4_K_M, Q8_0 |
| Gemma 4 12B | 12B | gemma4 | Apache-2.0 | 24 GB Macs | kept; adds Q4_K_M, Q8_0 |
| Gemma 4 26B-A4B | 25.2B (3.8B), MoE | gemma4 | Apache-2.0 | 32–48 GB Macs | kept; adds Q5_K_M, Q8_0 |
| Qwen3.6 35B-A3B | 36B (3B), MoE | qwen35moe | Apache-2.0 | 48–64 GB Macs | new |
| Qwen3.8 27B | 27.8B dense | qwen35 | Apache-2.0 | Max and Ultra chips | new; strongest model under 40B |

**Leaving the catalogue** (installed copies keep working under **On this
Mac**):

- SmolVLM2 2.2B: superseded by Qwen3.5 2B.
- Gemma 4 E4B: larger than Qwen3.5 4B and lower on both quality measures.
- Ministral 3 8B and 14B: no successor; outscored by Qwen3.5 9B and Gemma 4
  12B.
- MiniCPM-o 4.5: cannot be installed.

**Deferred to a later refresh:**

- 100B-class models for 128 GB Macs. The strongest, Qwen3.8-Flash-Next, has an
  open Metal out-of-memory bug (llama.cpp #29465) and a non-Apache license.
- MiniCPM-V 4.7 (released 2026-10-07): scores unverified and an open grounding
  bug.
- Muse Glimmer 30B: an open memory-growth bug after the first image.
- Gemma 4 31B: slower than Qwen3.8 27B and lower on the quality index.

**Expected picks.** Calculated with this design's formulas from published
bandwidth, assuming the copy test reads 87% of it, the starting efficiency
constants, and October 2026 quality scores (Qwen3.8 27B 28, Qwen3.6 35B-A3B 18,
Gemma 4 26B-A4B 17, Gemma 4 12B 14, Qwen3.5 9B 13.5, Qwen3.5 4B 13, Qwen3.5 2B
8). Not measured; real picks follow each Mac's measured bandwidth.

| Mac | Recommended | Faster | Smarter, slower |
|---|---|---|---|
| 8 GB M1 | Qwen3.5 2B Q4_K_M, ~32 tok/s | — | — |
| 16 GB M4 | Qwen3.5 4B Q5_K_M, ~23 tok/s | Qwen3.5 2B | Qwen3.5 9B Q4_K_M, ~13 tok/s |
| 24 GB M5 Pro | Gemma 4 12B Q5_K_M, ~24 tok/s (~27 once calibrated) | Qwen3.5 4B Q8_0 | — |
| 32 GB M2 Max | Gemma 4 26B-A4B Q4_K_M, ~61 tok/s | — | — |
| 36 GB M3 Pro | Gemma 4 26B-A4B Q5_K_M, ~20 tok/s | Qwen3.5 2B | — |
| 48 GB M4 Pro | Qwen3.6 35B-A3B Q5_K_M, ~49 tok/s | — | Qwen3.8 27B Q4_K_M, ~10 tok/s |
| 64 GB M5 Max | Qwen3.6 35B-A3B Q8_0, ~57 tok/s | — | Qwen3.8 27B Q4_K_M, ~17 tok/s |
| 128 GB M5 Max | Qwen3.8 27B Q4_K_M, ~23 tok/s | Qwen3.6 35B-A3B Q8_0 | — |
| 256 GB M5 Ultra | Qwen3.8 27B Q8_0, ~28 tok/s | Qwen3.6 35B-A3B Q8_0 | — |

The 24 GB M5 Pro row is a test fixture (see Testing).

### 6. Runtime bump

`LocalVisionRuntime` moves from b10797 to the newest llama.cpp build that
passes the checks below (b11734 at the time of writing), with its size and
SHA-256 pinned as today.

- **Why:** b10797 decodes Gemma 4 image tokens non-causally, which garbles
  OCR (#28318, fixed in b10809). Later builds add Metal flash-attention and MoE
  kernels and image-encoder fixes.
- **Image tokens.** Since b11327, Gemma's image tokens are capped at the
  physical batch size (`-ub`, default 512). Enigma passes
  `--image-max-tokens 4096` and the default batch. The implementation sets the
  batch and image-token arguments so a full-screen screenshot is not cut to
  512 tokens.
- **Launch arguments.** Every argument Enigma passes still exists in b11734
  (the removed `--mmap` flags are not used). The launch-argument tests are
  updated for any change.
- **Real checks before shipping**, on an Apple Silicon Mac: a full-screen
  screenshot OCR question on Gemma 4 12B whose answer is not truncated, with
  peak memory inside the estimate; a screenshot question on a Qwen family; and
  **Check performance** on each.
- Exact benchmarks recorded on b10797 stop applying; efficiency calibration
  (section 1) keeps using them.

## Failure handling

- The bandwidth test never fails or delays the hardware check; a failure falls
  back to the core-count prior.
- Benchmarks of packages no longer in the catalogue still calibrate efficiency,
  so the existing Gemma 4 12B run improves estimates at once.
- Installed packages that leave the catalogue keep working and appear under
  **On this Mac**.
- Over-budget installs keep the memory warning; disk, runtime and Metal-buffer
  checks are unchanged.
- If a performance check shows a model well below its estimate, Enigma still
  suggests a faster package (`fasterAlternative(to:)`).

## Testing

All offline and deterministic unless marked opt-in.

- `LocalModelSelectionTests`, rewritten around the roles on synthetic Macs at
  8, 16, 24, 36, 64 and 128 GB with different bandwidths, including the 24 GB
  M5 Pro fixture (24 GiB, 17.76 GiB Metal working set, measured bandwidth
  ~270 GB/s) that asserts Gemma 4 12B is Recommended. Also: MoE speed uses
  active bytes; calibration has no cap and survives a runtime change; exact
  measurements win and require the same build; each family's quantization
  choice; the nothing-fast fallback; the nothing-fits message.
- The bandwidth test is injected as a closure, so suites never touch the GPU;
  clamping and fallback are unit-tested; a real-hardware check joins the
  existing opt-in real-model checks.
- Memory estimate against the recorded peaks above: each estimate is at least
  the measured peak and at most 25% above it. Sliding-window and hybrid cache
  sizes are unit-tested per profile.
- Catalogue: every package runnable, unique IDs and checksums, consistent
  family metadata, existing package IDs unchanged, older installed records
  decode.
- Runtime: launch arguments for the new build, including the batch and
  image-token settings.
- Settings, Welcome and ⌘K-sheet rendering tests updated in both themes.

## Docs

- `docs/Local-Model-Selection.md` rewritten: catalogue table, pinned
  repositories, how picks work, the memory and speed estimates, Discover
  removed, shorter privacy section.
- `docs/README.md`, `docs/Welcome-and-Settings.md` and the Local models
  screenshot updated.
- New `docs/Updating-the-Model-Catalogue.md`.
- Release notes for the next version.

## Out of scope

- Audio input or output.
- Installing arbitrary Hugging Face repositories.
- Configuring the signed remote catalogue.
- Changing the context size (8,192 tokens) or the memory budget formula.
- The deferred models listed in section 5.
