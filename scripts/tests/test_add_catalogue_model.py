"""Offline tests for scripts/add-catalogue-model.py.

Run with: python3 -I -B -m unittest discover -s scripts/tests
"""

import importlib.util
import io
import json
import struct
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


add = load("add_catalogue_model", "add-catalogue-model.py")
header = load("gguf_header", "gguf-header.py")

REPO = "example/Fixture-GGUF"
REVISION = "0123456789abcdef0123456789abcdef01234567"


def encode_string(text):
    data = text.encode("utf-8")
    return struct.pack("<Q", len(data)) + data


def encode_value(value):
    if isinstance(value, bool):
        return struct.pack("<I?", 7, value)
    if isinstance(value, int):
        return struct.pack("<II", 4, value)
    if isinstance(value, str):
        return struct.pack("<I", 8) + encode_string(value)
    if isinstance(value, list):
        element = 7 if isinstance(value[0], bool) else 4
        form = "?" if element == 7 else "I"
        return struct.pack("<IIQ", 9, element, len(value)) + b"".join(struct.pack("<" + form, v) for v in value)
    raise TypeError(value)


def gguf(metadata, tensors):
    """A GGUF v3 header: metadata, then (name, offset) tensor infos."""
    out = b"GGUF" + struct.pack("<IQQ", 3, len(tensors), len(metadata))
    for key, value in metadata.items():
        out += encode_string(key) + encode_value(value)
    for name, offset in tensors:
        out += encode_string(name) + struct.pack("<IQIQ", 1, 16, 0, offset)
    return out


GEMMA = {
    "general.architecture": "gemma4",
    "gemma4.block_count": 6,
    "gemma4.attention.head_count_kv": [8, 8, 2, 8, 8, 2],
    "gemma4.attention.key_length": 512,
    "gemma4.attention.value_length": 512,
    "gemma4.attention.key_length_swa": 256,
    "gemma4.attention.value_length_swa": 256,
    "gemma4.attention.sliding_window": 1024,
    "gemma4.attention.sliding_window_pattern": [True, True, False, True, True, False],
}
PROJECTOR = {
    "general.architecture": "clip",
    "clip.has_vision_encoder": True,
    "clip.vision.projector_type": "gemma4v",
}

FILES = {
    "Fixture-7B-Q4_K_M.gguf": gguf(GEMMA, [("token_embd.weight", 0), ("blk.0.attn_q.weight", 2_500_000_000),
                                           ("output_norm.weight", 2_600_000_000)]),
    "Fixture-7B-UD-IQ3_XXS.gguf": gguf(GEMMA, [("token_embd.weight", 0), ("blk.0.attn_q.weight", 2_000_000_000),
                                               ("output_norm.weight", 2_100_000_000)]),
    "mmproj-F16.gguf": gguf(PROJECTOR, [("v.patch_embd.weight", 0)]),
}


class Network:
    """Serves the saved tree and the synthetic headers; records what was asked."""

    def __init__(self):
        self.requests = []
        self.tree = json.loads((FIXTURES / "tree.json").read_text())

    def fetch_json(self, url):
        self.requests.append(url)
        if url == f"https://huggingface.co/api/models/{REPO}/revision/main":
            return {"sha": REVISION}
        if url == f"https://huggingface.co/api/models/{REPO}/tree/{REVISION}":
            return self.tree
        raise AssertionError(f"Unexpected request {url}")

    def open_reader(self, url):
        self.requests.append(url)
        prefix = f"https://huggingface.co/{REPO}/resolve/{REVISION}/"
        assert url.startswith(prefix), url
        data = FILES[url[len(prefix):]]
        return header.HeaderReader(lambda start, count: data[start:start + count])


def run(*arguments):
    network = Network()
    out = io.StringIO()
    add.main(list(arguments), fetch_json=network.fetch_json, open_reader=network.open_reader, out=out)
    return out.getvalue(), network


EXPECTED = """\
// Family entry for Enigma/LocalInference/BundledLocalModels.swift
    LocalModelFamily(name: "Fixture 7B", publisher: "Fixture Labs", license: "Apache-2.0", profile: .fixture7B,
      // <source of the quality score, with its date>
      qualityScore: 12,
      summary: "A fixture model for tests.",
      repository: "example/Fixture-GGUF", revision: "0123456789abcdef0123456789abcdef01234567",
      projectorFile: "mmproj-F16.gguf", projectorByteCount: 900000000,
      projectorSHA256: "3e3f3f593b34bb4f518ada3e7999e4cbcd2a5864fa86ebc23fad3cbc4fbeba40", supportsAudio: false,
      packages: [
        .init(id: "fixture-7b-iq3_xxs", quantization: "IQ3_XXS", file: "Fixture-7B-UD-IQ3_XXS.gguf",
              byteCount: 3500000000, sha256: "c9f34994715a016cd0bcd7ff4c1f5710718bbcc25d40796302db0a89b6d0d8ea",
              largestTensorBytes: 2000000000),
        .init(id: "fixture-7b-q4_k_m", quantization: "Q4_K_M", file: "Fixture-7B-Q4_K_M.gguf",
              byteCount: 4000000000, sha256: "2959c1b0a4f792493bb0092846ea06aec54547e47be979c282634d938d501b75",
              largestTensorBytes: 2500000000),
      ]),

// Cache layout for LocalMultimodalProfile.cacheLayout
    LocalCacheLayout(fullLayers: 2, fullKVHeads: 2, fullHeadDimension: 512,
                     slidingLayers: 4, slidingKVHeads: 8, slidingHeadDimension: 256, slidingWindow: 1024)

// Profile facts
// architecture: gemma4 · 6 blocks · dense
// projector: gemma4v · vision only
// quantizations to allow: IQ3_XXS, Q4_K_M
"""


class AddCatalogueModelTests(unittest.TestCase):
    def test_prints_the_family_entry_and_cache_layout(self):
        output, network = run("--repo", REPO, "--revision", REVISION, "--projector", "mmproj-F16.gguf",
                              "--file", "Fixture-7B-Q4_K_M.gguf", "--file", "Fixture-7B-UD-IQ3_XXS.gguf",
                              "--name", "Fixture 7B", "--publisher", "Fixture Labs", "--license", "Apache-2.0",
                              "--profile", "fixture7B", "--quality", "12", "--summary", "A fixture model for tests.")
        self.assertEqual(output, EXPECTED)
        self.assertNotIn(f"https://huggingface.co/api/models/{REPO}/revision/main", network.requests)

    def test_resolves_main_to_its_commit(self):
        output, network = run("--repo", REPO, "--projector", "mmproj-F16.gguf", "--file", "Fixture-7B-Q4_K_M.gguf")
        self.assertEqual(network.requests[0], f"https://huggingface.co/api/models/{REPO}/revision/main")
        self.assertIn(f'revision: "{REVISION}"', output)
        self.assertIn('LocalModelFamily(name: "<name>", publisher: "<publisher>", license: "<license>", '
                      'profile: .<profile>,', output)
        self.assertIn('.init(id: "<family>-q4_k_m", quantization: "Q4_K_M"', output)

    def test_label_overrides_the_file_name(self):
        output, _ = run("--repo", REPO, "--revision", REVISION, "--projector", "mmproj-F16.gguf",
                        "--file", "Fixture-7B-Q4_K_M.gguf", "--label", "Q4_0", "--name", "Fixture 7B")
        self.assertIn('.init(id: "fixture-7b-q4_0", quantization: "Q4_0", file: "Fixture-7B-Q4_K_M.gguf",', output)

    def test_labels_drop_the_unsloth_dynamic_prefix(self):
        self.assertEqual(add.label_for("Qwen3.8-27B-UD-IQ4_XS.gguf"), "IQ4_XS")
        self.assertEqual(add.label_for("google_gemma-4-31B-it-Q8_0.gguf"), "Q8_0")
        self.assertEqual(add.label_for("Qwen3.5-9B-Q3_K_M.gguf"), "Q3_K_M")
        self.assertEqual(add.label_for("gemma-4-12b-it-UD-IQ3_XXS.gguf"), "IQ3_XXS")

    def test_a_file_missing_at_the_revision_fails(self):
        with self.assertRaises(SystemExit) as raised:
            run("--repo", REPO, "--revision", REVISION, "--projector", "mmproj-F16.gguf",
                "--file", "Fixture-7B-Q5_K_M.gguf")
        self.assertIn("Fixture-7B-Q5_K_M.gguf is not in example/Fixture-GGUF at 0123456", str(raised.exception))

    def test_a_branch_name_is_not_a_pin(self):
        with self.assertRaises(SystemExit):
            run("--repo", REPO, "--revision", "main", "--projector", "mmproj-F16.gguf",
                "--file", "Fixture-7B-Q4_K_M.gguf")

    def test_hybrid_layout_counts_attention_and_prediction_layers(self):
        metadata = {
            "general.architecture": "qwen35",
            "qwen35.block_count": 65,
            "qwen35.attention.head_count_kv": 4,
            "qwen35.attention.key_length": 256,
            "qwen35.attention.value_length": 256,
            "qwen35.full_attention_interval": 4,
            "qwen35.nextn_predict_layers": 1,
        }
        self.assertEqual(add.cache_layout(metadata),
                         {"fullLayers": 17, "fullKVHeads": 4, "fullHeadDimension": 256})

    def test_dense_layout_uses_every_block(self):
        metadata = {
            "general.architecture": "mistral3",
            "mistral3.block_count": 34,
            "mistral3.attention.head_count_kv": 8,
            "mistral3.attention.key_length": 128,
            "mistral3.attention.value_length": 128,
        }
        self.assertEqual(add.cache_layout(metadata),
                         {"fullLayers": 34, "fullKVHeads": 8, "fullHeadDimension": 128})

    def test_older_projectors_name_their_type_without_the_vision_prefix(self):
        FILES["mmproj-F16.gguf"] = gguf({"general.architecture": "clip", "clip.has_vision_encoder": True,
                                         "clip.projector_type": "qwen3vl_merger"}, [("v.patch_embd.weight", 0)])
        try:
            output, _ = run("--repo", REPO, "--revision", REVISION, "--projector", "mmproj-F16.gguf",
                            "--file", "Fixture-7B-Q4_K_M.gguf")
        finally:
            FILES["mmproj-F16.gguf"] = gguf(PROJECTOR, [("v.patch_embd.weight", 0)])
        self.assertIn("// projector: qwen3vl_merger · vision only", output)

    def test_header_reader_finds_the_largest_tensor(self):
        data = FILES["Fixture-7B-Q4_K_M.gguf"]
        largest, name, metadata = header.read_header(
            header.HeaderReader(lambda start, count: data[start:start + count]), 4_000_000_000)
        self.assertEqual((largest, name), (2_500_000_000, "token_embd.weight"))
        self.assertEqual(metadata["gemma4.block_count"], 6)


if __name__ == "__main__":
    unittest.main()
