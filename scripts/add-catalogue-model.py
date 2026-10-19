#!/usr/bin/env python3
"""Print a catalogue entry for a Hugging Face GGUF repository.

Usage:
  python3 -I scripts/add-catalogue-model.py --repo <owner/name> [--revision <commit>]
      --projector <mmproj file> --file <gguf> [--label <quantization>] [--file <gguf> ...]
      [--name <family name>] [--publisher <name>] [--license <id>] [--profile <case>]
      [--quality <score>] [--summary <sentence>]

Pins the revision (resolving `main` to its commit when --revision is left
out), takes each file's size and SHA-256 from the tree API, reads each GGUF
header with HTTP Range requests (scripts/gguf-header.py), and prints a
`LocalModelFamily` entry in the style of BundledLocalModels.swift plus the
cache-layout facts for LocalMultimodalProfile. It never writes into the
repository. A --label follows the --file it names; without one the label comes
from the file name, without Unsloth's `UD-` prefix. Standard library only.
"""

import argparse
import importlib.util
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("gguf_header", Path(__file__).resolve().parent / "gguf-header.py")
gguf_header = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gguf_header)

HUB = "https://huggingface.co"


def fetch_json(url):
    with urllib.request.urlopen(url) as response:
        return json.load(response)


def label_for(file):
    parts = Path(file).stem.split("-")
    return parts[-1].upper()


def head_dimension(key, value):
    # LocalCacheLayout counts 4 bytes per head dimension: K and V at F16.
    return (key + value) // 2


def cache_layout(metadata):
    """The LocalCacheLayout fields for a model's GGUF metadata."""
    architecture = metadata["general.architecture"]

    def get(key, default=None):
        return metadata.get(f"{architecture}.{key}", default)

    blocks = get("block_count")
    heads = get("attention.head_count_kv")
    key = get("attention.key_length")
    value = get("attention.value_length", key)
    pattern = get("attention.sliding_window_pattern")
    window = get("attention.sliding_window")

    def heads_at(index):
        return heads[index] if isinstance(heads, list) else heads

    def one(values, kind):
        values = set(values)
        if len(values) != 1:
            raise SystemExit(f"The {kind} layers have different KV head counts ({sorted(values)}); check by hand.")
        return values.pop()

    if isinstance(pattern, list) and window:
        sliding = [index for index, is_sliding in enumerate(pattern) if is_sliding]
        full = [index for index, is_sliding in enumerate(pattern) if not is_sliding]
        swa_key = get("attention.key_length_swa", key)
        swa_value = get("attention.value_length_swa", swa_key)
        return {
            "fullLayers": len(full), "fullKVHeads": one(map(heads_at, full), "full-attention"),
            "fullHeadDimension": head_dimension(key, value),
            "slidingLayers": len(sliding), "slidingKVHeads": one(map(heads_at, sliding), "sliding-window"),
            "slidingHeadDimension": head_dimension(swa_key, swa_value), "slidingWindow": window,
        }
    if isinstance(heads, list):
        attention = [count for count in heads if count]
        return {"fullLayers": len(attention), "fullKVHeads": one(attention, "attention"),
                "fullHeadDimension": head_dimension(key, value)}
    # Hybrid models hold a cache only in every `interval`-th layer, plus their
    # multi-token-prediction layers, which are attention layers.
    interval = get("full_attention_interval")
    predicted = get("nextn_predict_layers", 0)
    layers = (blocks - predicted) // interval + predicted if interval else blocks
    return {"fullLayers": layers, "fullKVHeads": heads, "fullHeadDimension": head_dimension(key, value)}


def swift_layout(layout):
    full = (f"LocalCacheLayout(fullLayers: {layout['fullLayers']}, fullKVHeads: {layout['fullKVHeads']}, "
            f"fullHeadDimension: {layout['fullHeadDimension']}")
    if "slidingLayers" not in layout:
        return f"    {full})"
    return (f"    {full},\n                     slidingLayers: {layout['slidingLayers']}, "
            f"slidingKVHeads: {layout['slidingKVHeads']}, slidingHeadDimension: {layout['slidingHeadDimension']}, "
            f"slidingWindow: {layout['slidingWindow']})")


class FileAction(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        files = getattr(namespace, "files", None) or []
        if option_string == "--file":
            files.append([values, None])
        elif not files:
            parser.error("--label must follow the --file it names")
        else:
            files[-1][1] = values
        namespace.files = files


def parse(argv):
    parser = argparse.ArgumentParser(prog="add-catalogue-model.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--revision")
    parser.add_argument("--projector", required=True)
    parser.add_argument("--file", action=FileAction, dest="files", required=True)
    parser.add_argument("--label", action=FileAction, dest="files")
    for option in ["name", "publisher", "license", "profile", "summary"]:
        parser.add_argument(f"--{option}", default=f"<{option}>")
    parser.add_argument("--quality", default="<score>")
    return parser.parse_args(argv)


def main(argv=None, fetch_json=fetch_json, open_reader=gguf_header.RemoteFile, out=None):
    out = out or sys.stdout
    options = parse(sys.argv[1:] if argv is None else argv)
    repo = options.repo
    quoted = urllib.parse.quote(repo, safe="/")
    revision = options.revision
    if revision is None:
        revision = fetch_json(f"{HUB}/api/models/{quoted}/revision/main")["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit(f"{revision} is not a commit. Pass a 40-character commit, or leave out --revision "
                         "to pin the current main.")
    tree = {entry["path"]: entry["lfs"] for entry in fetch_json(f"{HUB}/api/models/{quoted}/tree/{revision}")
            if "lfs" in entry}

    def pinned(file):
        if file not in tree:
            raise SystemExit(f"{file} is not in {repo} at {revision[:7]}.")
        return tree[file]["size"], tree[file]["oid"]

    def header(file, size):
        return gguf_header.read_header(open_reader(f"{HUB}/{repo}/resolve/{revision}/{file}"), size)

    projector_bytes, projector_sha = pinned(options.projector)
    _, _, projector = header(options.projector, projector_bytes)
    audio = bool(projector.get("clip.has_audio_encoder", False))

    stem = options.name.lower().replace(" ", "-") if options.name != "<name>" else "<family>"
    packages = []
    for file, label in options.files:
        size, sha = pinned(file)
        largest, _, metadata = header(file, size)
        packages.append((size, label or label_for(file), file, sha, largest, metadata))
    packages.sort(key=lambda package: package[0])

    write = lambda line="": print(line, file=out)
    write("// Family entry for Enigma/LocalInference/BundledLocalModels.swift")
    write(f'    LocalModelFamily(name: "{options.name}", publisher: "{options.publisher}", '
          f'license: "{options.license}", profile: .{options.profile},')
    write("      // <source of the quality score, with its date>")
    write(f"      qualityScore: {options.quality},")
    write(f'      summary: "{options.summary}",')
    write(f'      repository: "{repo}", revision: "{revision}",')
    write(f'      projectorFile: "{options.projector}", projectorByteCount: {projector_bytes},')
    write(f'      projectorSHA256: "{projector_sha}", supportsAudio: {"true" if audio else "false"},')
    write("      packages: [")
    for size, label, file, sha, largest, _ in packages:
        write(f'        .init(id: "{stem}-{label.lower()}", quantization: "{label}", file: "{file}",')
        write(f'              byteCount: {size}, sha256: "{sha}",')
        write(f"              largestTensorBytes: {largest}),")
    write("      ]),")

    layouts = [cache_layout(package[5]) for package in packages]
    write()
    write("// Cache layout for LocalMultimodalProfile.cacheLayout")
    write(swift_layout(layouts[0]))
    if any(layout != layouts[0] for layout in layouts):
        write("// warning: the packages' headers disagree on the cache layout; check by hand")

    metadata = packages[0][5]
    architecture = metadata["general.architecture"]
    experts = metadata.get(f"{architecture}.expert_count")
    used = metadata.get(f"{architecture}.expert_used_count")
    kind = f"mixture of experts ({used} of {experts} experts per token)" if experts else "dense"
    projector_type = projector.get("clip.vision.projector_type", projector.get("clip.projector_type", "unknown"))
    write()
    write("// Profile facts")
    write(f"// architecture: {architecture} · {metadata.get(f'{architecture}.block_count')} blocks · {kind}")
    write(f"// projector: {projector_type} · {'vision and audio' if audio else 'vision only'}")
    write(f"// quantizations to allow: {', '.join(package[1] for package in packages)}")


if __name__ == "__main__":
    main()
