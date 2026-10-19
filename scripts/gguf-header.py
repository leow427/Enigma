#!/usr/bin/env python3
"""Read a remote GGUF header for the model catalogue.

Usage: python3 -I scripts/gguf-header.py <resolve URL> <file bytes>

Reads only the header (metadata and tensor infos) with HTTP Range requests in
4 MiB steps and prints the largest tensor and the cache-layout keys that
docs/Updating-the-Model-Catalogue.md asks for. Standard library only.
scripts/add-catalogue-model.py reuses `HeaderReader`, `RemoteFile` and
`read_header`.
"""

import struct
import sys
import urllib.request

STEP = 4 * 1024 * 1024
LAYOUT_KEYS = [
    "block_count", "attention.head_count_kv", "attention.key_length", "attention.value_length",
    "attention.key_length_swa", "attention.value_length_swa",
    "attention.sliding_window", "attention.sliding_window_pattern", "full_attention_interval",
    "nextn_predict_layers", "expert_count", "expert_used_count",
]


class HeaderReader:
    """Reads a GGUF header from `fetch(start, count)`, which returns up to `count` bytes."""

    def __init__(self, fetch):
        self.fetch = fetch
        self.data = b""
        self.position = 0

    def _fetch_until(self, end):
        while len(self.data) < end:
            chunk = self.fetch(len(self.data), STEP)
            if not chunk:
                raise SystemExit("The file ended inside its header.")
            self.data += chunk

    def read(self, count):
        self._fetch_until(self.position + count)
        value = self.data[self.position:self.position + count]
        self.position += count
        return value

    def unpack(self, form):
        size = struct.calcsize(form)
        return struct.unpack("<" + form, self.read(size))[0]

    def string(self):
        return self.read(self.unpack("Q")).decode("utf-8", errors="replace")


def range_fetcher(url):
    def fetch(start, count):
        request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start + count - 1}"})
        with urllib.request.urlopen(request) as response:
            if response.status != 206:
                raise SystemExit(f"The server ignored the Range request (HTTP {response.status}).")
            return response.read()
    return fetch


class RemoteFile(HeaderReader):
    def __init__(self, url):
        super().__init__(range_fetcher(url))
        self.url = url


SCALARS = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


def value(reader, kind):
    if kind in SCALARS:
        return reader.unpack(SCALARS[kind])
    if kind == 8:
        return reader.string()
    if kind == 9:
        element = reader.unpack("I")
        count = reader.unpack("Q")
        return [value(reader, element) for _ in range(count)]
    raise SystemExit(f"Unknown GGUF value type {kind}.")


def read_header(reader, file_bytes):
    """Returns (largest tensor bytes, its name, metadata) for a GGUF v3 file of `file_bytes`."""
    if reader.read(4) != b"GGUF":
        raise SystemExit("Not a GGUF file.")
    version = reader.unpack("I")
    if version != 3:
        raise SystemExit(f"GGUF version {version} is not supported; expected 3.")
    tensor_count = reader.unpack("Q")
    metadata_count = reader.unpack("Q")
    metadata = {}
    for _ in range(metadata_count):
        key = reader.string()
        metadata[key] = value(reader, reader.unpack("I"))
    tensors = []
    for _ in range(tensor_count):
        name = reader.string()
        dimensions = reader.unpack("I")
        for _ in range(dimensions):
            reader.unpack("Q")
        reader.unpack("I")  # tensor type
        tensors.append((reader.unpack("Q"), name))
    alignment = metadata.get("general.alignment", 32)
    data_start = (reader.position + alignment - 1) // alignment * alignment
    tensors.sort()
    largest = (0, "")
    for index, (offset, name) in enumerate(tensors):
        end = tensors[index + 1][0] if index + 1 < len(tensors) else file_bytes - data_start
        largest = max(largest, (end - offset, name))
    return largest[0], largest[1], metadata


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    url, file_bytes = sys.argv[1], int(sys.argv[2])
    largest, name, metadata = read_header(RemoteFile(url), file_bytes)
    print(f"largestTensorBytes {largest} {name}")
    architecture = metadata.get("general.architecture", "unknown")
    for key in LAYOUT_KEYS:
        full = f"{architecture}.{key}"
        if full in metadata:
            shown = metadata[full]
            if isinstance(shown, list) and len(shown) > 64:
                shown = f"[{len(shown)} values]"
            print(f"{full} {shown}")


if __name__ == "__main__":
    main()
