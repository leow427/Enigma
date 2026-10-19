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
  with `--ubatch-size` large enough for a whole screenshot. The runtime
  decides this in `mtmd_decode_use_non_causal` (`tools/mtmd/mtmd.cpp`) from
  the projector type, which the add-model script prints: in b11734 every
  Gemma 4 projector is non-causal except E2B's and E4B's.
- A family that needs a newer llama.cpp bumps `LocalVisionRuntime` (build,
  archive sizes and SHA-256) in the same release. Check that every launch
  argument still exists in the new build's `common/arg.cpp`.

## 3. Pin the files and read the headers

Run the add-model script with the repository, its projector and each GGUF the
catalogue should ship:

```sh
python3 -I scripts/add-catalogue-model.py --repo bartowski/google_gemma-4-31B-it-GGUF \
  --projector mmproj-google_gemma-4-31B-it-f16.gguf \
  --file google_gemma-4-31B-it-Q4_K_M.gguf --file google_gemma-4-31B-it-Q8_0.gguf \
  --name "Gemma 4 31B" --publisher Google --license Apache-2.0 --profile gemma4_31B
```

It reads and prints only; it never writes into the repository.

- **Revision.** Without `--revision` it resolves `main` to its 40-character
  commit and pins that; a branch name passed as `--revision` is refused.
  Weights and projector come from that one repository and revision.
- **Sizes and SHA-256** come from the tree API
  (`https://huggingface.co/api/models/<repository>/tree/<revision>`, each
  file's `lfs.size` and `lfs.oid`). A file missing at the revision stops the
  script.
- **Headers.** It reads each GGUF header, and the projector's, with HTTP range
  requests (through `scripts/gguf-header.py`), for the largest tensor, block
  count, KV heads, head dimensions, sliding window and experts.
- **Labels and IDs.** The quantization label comes from the file name without
  Unsloth's `UD-` prefix (`Qwen3.8-27B-UD-IQ3_XXS.gguf` is `IQ3_XXS`); pass
  `--label <quantization>` right after a `--file` to override it. IDs are
  `<family>-<quantization>`, with the family from `--name` lowercased and
  spaced with hyphens. Keep the IDs of existing packages, so installed copies
  and benchmarks carry over.

It prints three blocks:

1. A `LocalModelFamily` entry for `BundledLocalModels.swift`, packages in size
   order, with `supportsAudio` from the projector header. Fields you didn't
   pass print as `<placeholders>`; fill in the quality score and its source
   (step 5). To add sizes to an existing family, paste only the `.init` lines.
2. The `LocalCacheLayout` for `LocalMultimodalProfile.cacheLayout`: full
   attention layers, sliding-window layers, their KV heads and head
   dimensions, and the window. Hybrid models count only their attention
   layers (every `full_attention_interval`-th layer) plus any
   multi-token-prediction layers. It warns if the packages' headers disagree.
3. Profile facts: architecture, block count, dense or mixture of experts, the
   projector type and whether it carries audio, and the quantizations to add
   to the profile's `quantizations`. Record total and active parameters
   (`parameters`, `activeParameters`) and `isMixtureOfExperts` by hand.

Add any new quantization label to `LocalQuantization.precisionOrder` and
`qualityFactor` in `LocalModelSelection.swift`, too.

## 4. Check the header by hand when needed

`scripts/gguf-header.py` prints one file's raw layout keys, for a family the
add-model script can't lay out (it stops when layers of one kind have
different KV head counts):

```sh
python3 -I scripts/gguf-header.py <resolve URL> <file bytes>
```

It prints the largest tensor and `block_count`, `attention.head_count_kv`,
`attention.key_length`, `attention.value_length`,
`attention.key_length_swa`, `attention.value_length_swa`,
`attention.sliding_window`, `attention.sliding_window_pattern`,
`full_attention_interval`, `nextn_predict_layers`, `expert_count` and
`expert_used_count`.

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

Run the script tests after changing either catalogue script:

```sh
python3 -I -B -m unittest discover -s scripts/tests
```

Then, on an Apple Silicon Mac, running Enigma from Xcode with a stable
signing identity:

1. Install one new package from Settings → Local models.
2. Ask a question about a full-screen screenshot and check the answer is not
   cut short.
3. Run **Check performance** and check the peak memory stays inside the
   package's estimate.
