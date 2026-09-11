"""Regenerate tiny Safetensors interoperability fixtures with the official library.

Run from the repository root with an isolated tool environment:
    uv run --no-project --with safetensors==0.8.0 python tests/generate_safetensors_fixtures.py

The kernel and Sig tests read checked-in bytes; Python and safetensors are only
optional fixture-generation tools. No NumPy, PyTorch, model weights, or network
service is used. A different safetensors version requires an explicit fixture
review rather than silently changing the reference implementation.
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import struct
from pathlib import Path

import safetensors

REFERENCE_VERSION = "0.8.0"
OUT = Path(__file__).resolve().parent / "fixtures" / "safetensors"


def tensor(dtype: str, shape: list[int], data: bytes) -> dict:
    return {"dtype": dtype, "shape": shape, "data": data}


def serialize(tensors: dict) -> bytes:
    dtype_names = {
        "BOOL": "bool", "I8": "int8", "U8": "uint8", "I16": "int16", "U16": "uint16",
        "I32": "int32", "U32": "uint32", "I64": "int64", "U64": "uint64",
        "BF16": "bfloat16", "F16": "float16", "F32": "float32", "F64": "float64",
    }
    # TensorSpec is the official 0.8 API. Keep owned ctypes buffers alive until
    # serialization returns, including a valid allocation for zero-byte data.
    buffers = {name: ctypes.create_string_buffer(value["data"]) for name, value in tensors.items()}
    specs = {
        name: safetensors.TensorSpec(
            dtype=dtype_names[value["dtype"]], shape=value["shape"],
            data_ptr=ctypes.addressof(buffers[name]), data_len=len(value["data"]),
        )
        for name, value in tensors.items()
    }
    return safetensors.serialize(specs, metadata={"generator": f"safetensors {REFERENCE_VERSION}"})


def validate(encoded: bytes, expected: dict) -> None:
    decoded = dict(safetensors.deserialize(encoded))
    assert decoded.keys() == expected.keys()
    for name, value in expected.items():
        actual = decoded[name]
        assert actual["dtype"] == value["dtype"], name
        assert actual["shape"] == value["shape"], name
        assert bytes(actual["data"]) == value["data"], name


def reorder_header(encoded: bytes) -> bytes:
    """Exercise a legal header order differing from ascending tensor offsets."""
    header_length = struct.unpack_from("<Q", encoded)[0]
    metadata = json.loads(encoded[8 : 8 + header_length])
    reordered = dict(reversed(list(metadata.items())))
    header = json.dumps(reordered, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    header += b" " * (-len(header) % 8)
    return struct.pack("<Q", len(header)) + header + encoded[8 + header_length :]


def main() -> None:
    if safetensors.__version__ != REFERENCE_VERSION:
        raise SystemExit(f"Expected official safetensors {REFERENCE_VERSION}, got {safetensors.__version__}")
    float_tensors = {
        "bf16": tensor("BF16", [2], struct.pack("<HH", 0x3F80, 0xC000)),
        "f16": tensor("F16", [2], struct.pack("<ee", 0.5, -4.0)),
        "f32": tensor("F32", [2], struct.pack("<ff", -0.25, 3.5)),
    }
    integers = {
        "bool": tensor("BOOL", [2], b"\x00\x01"),
        "i8": tensor("I8", [2], struct.pack("<bb", -128, 127)),
        "u8": tensor("U8", [2], struct.pack("<BB", 0, 255)),
        "i16": tensor("I16", [2], struct.pack("<hh", -32768, 32767)),
        "u16": tensor("U16", [2], struct.pack("<HH", 0, 65535)),
        "i32": tensor("I32", [2], struct.pack("<ii", -2147483648, 2147483647)),
        "u32": tensor("U32", [2], struct.pack("<II", 0, 4294967295)),
        "i64": tensor("I64", [2], struct.pack("<qq", -9223372036854775808, 9223372036854775807)),
        "u64": tensor("U64", [2], struct.pack("<QQ", 0, 18446744073709551615)),
    }
    empty_scalar = {
        "empty": tensor("F16", [2, 0, 3], b""),
        "scalar": tensor("F32", [], struct.pack("<f", 3.5)),
        "scalar_f64": tensor("F64", [], struct.pack("<d", 1.25)),
    }
    cases = [
        ("floats.bin", float_tensors, False),
        ("integers.bin", integers, False),
        ("empty-scalar.bin", empty_scalar, False),
        ("mixed-order.bin", {**float_tensors, **empty_scalar}, True),
    ]
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {
        "schema": "zpm.safetensors.reference.v1",
        "reference_package": f"safetensors=={REFERENCE_VERSION}",
        "reference_source": "https://github.com/safetensors/safetensors",
        "fixtures": [],
    }
    for filename, tensors, reorder in cases:
        encoded = serialize(tensors)
        validate(encoded, tensors)
        if reorder:
            encoded = reorder_header(encoded)
            validate(encoded, tensors)
        (OUT / filename).write_bytes(encoded)
        header_length = struct.unpack_from("<Q", encoded)[0]
        header = json.loads(encoded[8 : 8 + header_length])
        item = {
            "file": filename,
            "sha256": hashlib.sha256(encoded).hexdigest(),
            "bytes": len(encoded),
            "header_bytes": header_length,
            "reordered_header": reorder,
            "tensors": {
                name: {**header[name], "data_hex": value["data"].hex()}
                for name, value in sorted(tensors.items())
            },
        }
        manifest["fixtures"].append(item)
        print(f"{item['sha256']}  {filename} ({len(encoded)} bytes)")
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
