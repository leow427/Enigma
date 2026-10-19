# Updating the model catalogue

The local model catalogue lives in code
(`Enigma/LocalInference/BundledLocalModels.swift`) and ships with app
releases. A refresh is an ordinary Sparkle release that follows this
checklist. [Local models](Local-Model-Selection.md) explains how Enigma picks
from the catalogue.

## 1. Find candidates

- Look for current open-weight models with image input that score well on the
  Artificial Analysis Intelligence Index and MMMU-Pro, across the memory sizes
  Macs ship with (8 GB to 128 GB and above).
- Prefer Apache-2.0 or similarly permissive licences.
- Check the llama.cpp issue tracker for open bugs with the model on Metal
  (out-of-memory, memory growth after the first image, grounding).

## 2. Confirm the runtime supports it

- The pinned `llama-server` build (`LocalVisionRuntime` in
  `Enigma/LocalInference/LlamaServerVisionEngine.swift`) must support the
  model's architecture and its projector, for text and for images.
- Find out whether the model's image tokens use non-causal attention. Since
  llama.cpp b11327 such models cap an image at the physical batch size, so
  their profile sets `usesNonCausalImageAttention` and Enigma launches them
  with `--ubatch-size` large enough for a whole screenshot.
- A family that needs a newer llama.cpp bumps `LocalVisionRuntime` (build,
  archive sizes and SHA-256) in the same release. Check that every launch
  argument still exists in the new build's `common/arg.cpp`.

## 3. Pin the files

- Weights and projector come from one repository and one revision.
- Pin the full 40-character revision, never a branch.
- Sizes and SHA-256 come from the Hugging Face tree API:
  `curl https://huggingface.co/api/models/<repository>/tree/<revision>`
  gives each file's `lfs.size` and `lfs.oid`.
- Keep the package IDs of existing packages, so installed copies and
  benchmarks carry over. New packages follow `<family>-<quantization>`.

## 4. Read the header

Run the header script for each package:

```sh
python3 -I scripts/gguf-header.py <resolve URL> <file bytes>
```

It reads only the GGUF header, with HTTP range requests, and prints the
largest tensor (`largestTensorBytes`) and the cache-layout keys:
`block_count`, `attention.head_count_kv`, `attention.key_length`,
`attention.value_length`, `attention.sliding_window`,
`attention.sliding_window_pattern`, `full_attention_interval`,
`nextn_predict_layers`, `expert_count` and `expert_used_count`.

- Record `largestTensorBytes` on the package.
- Record the cache layout in `LocalMultimodalProfile.cacheLayout`: full
  attention layers, sliding-window layers, their KV heads and head
  dimensions, and the window. Hybrid models count only their attention
  layers; a multi-token-prediction layer is an attention layer and counts.
- Record total and active parameters (`parameters`, `activeParameters`)
  and whether the model is a mixture of experts.
- Add the quantizations the catalogue ships to the profile's
  `quantizations`.

## 5. Set the quality score

- Use the Artificial Analysis Intelligence Index, checked against MMMU-Pro
  for vision, and write the source and date in a comment beside the score.
- Within one model line, a larger model of the same generation never scores
  below a smaller one; correct the score and say so in the comment.

## 6. Test

Run the catalogue, estimate and selection suites:

```sh
scripts/verify-xcode.sh test -only-testing:EnigmaTests/LocalModelCatalogueTests \
  -only-testing:EnigmaTests/LocalModelEstimateTests -only-testing:EnigmaTests/LocalModelSelectionTests
```

Update the expected picks in `LocalModelCatalogueTests` only after checking
them against the formulas in [Local models](Local-Model-Selection.md).

Then, on an Apple Silicon Mac, running Enigma from Xcode with a stable
signing identity:

1. Install one new package from Settings → Local models.
2. Ask a question about a full-screen screenshot and check the answer is not
   cut short.
3. Run **Check performance** and check the peak memory stays inside the
   package's estimate.
