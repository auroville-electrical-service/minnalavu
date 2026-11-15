# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Computes contract/fixtures/config.v1.digests.json, independently of the server and the collector.

Run from the repo root:
    uv run --script contract/tools/config_digest.py > contract/fixtures/config.v1.digests.json

The canonical encoding is Python's json.dumps with sorted keys, no whitespace
and no ASCII escaping, which for a polling config (integers, strings,
booleans, arrays and objects with ASCII keys) is RFC 8785's.
"""

import hashlib
import json
import sys
from functools import reduce
from pathlib import Path
from typing import cast

type Json = None | bool | int | str | list[Json] | dict[str, Json]
type Step = str | int

CONTRACT = Path(__file__).resolve().parent.parent

DESCRIPTION_SENTENCES = (
    "The digest of a polling config, as the server's ingest answer gives it in config_digest and a collector reports it in its backlog's config.",
    "Computed independently of either side by contract/tools/config_digest.py.",
    "The digest is SHA-256 over the UTF-8 bytes of the document's canonical encoding, as 64 lowercase hex digits.",
    "The canonical encoding is RFC 8785 (JCS), which for a polling config comes to: no whitespace; object keys sorted by their bytes; array elements in their order; integers in plain decimal; true, false and null as themselves;",
    'strings in double quotes with only " and \\ escaped (as \\" and \\\\) and the control characters below U+0020 (as \\b, \\t, \\n, \\f, \\r, or else \\u00 and two lowercase hex digits), everything else as itself, non-ASCII included.',
    "Each case is changes to config.v1.basic.json (set value at path, or remove the field when delete is true), as in config.v1.cases.json, with the canonical encoding and the digest it must give.",
    "A digest is computed for whatever the server serves, valid or not: an empty registry gives a config the collector refuses.",
)
DESCRIPTION = " ".join(DESCRIPTION_SENTENCES)

CASES: tuple[tuple[str, list[dict[str, Json]]], ...] = (
    ("the basic config", []),
    ("an empty registry", [{"path": ["endpoints"], "value": []}]),
    (
        "strings with characters that are escaped, and one that is not ASCII",
        [
            {
                "path": ["endpoints", 1, "host"],
                "value": 'gateway-"b"\\é.example.invalid',
            },
            {"path": ["endpoints", 0, "meters", 0, "serial"], "value": 'EX-"1"\\'},
        ],
    ),
)


def changed(document: Json, path: list[Step], change: dict[str, Json]) -> Json:
    step, rest = path[0], path[1:]
    match document, step:
        case list(), int():
            return [
                changed(x, rest, change) if i == step else x
                for i, x in enumerate(document)
            ]
        case dict(), str() if rest:
            return {**document, step: changed(document[step], rest, change)}
        case dict(), str() if change.get("delete") is True:
            return {k: v for k, v in document.items() if k != step}
        case dict(), str():
            return {**document, step: change["value"]}
        case _:
            raise ValueError(f"no {step} to change")


def steps(change: dict[str, Json]) -> list[Step]:
    path = change["path"]
    assert isinstance(path, list)
    return [s for s in path if isinstance(s, (str, int))]


def canonical(document: Json) -> str:
    return json.dumps(
        document, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )


def case(basic: Json, name: str, changes: list[dict[str, Json]]) -> dict[str, Json]:
    document = reduce(lambda d, c: changed(d, steps(c), c), changes, basic)
    text = canonical(document)
    return {
        "name": name,
        "changes": list[Json](changes),
        "canonical": text,
        "digest": hashlib.sha256(text.encode("utf-8")).hexdigest(),
    }


def fixture() -> dict[str, Json]:
    path = CONTRACT / "fixtures/config.v1.basic.json"
    basic = cast(Json, json.loads(path.read_text("utf-8")))
    return {
        "format": "config-digest/1",
        "description": DESCRIPTION,
        "cases": [case(basic, name, changes) for name, changes in CASES],
    }


if __name__ == "__main__":
    _ = sys.stdout.write(json.dumps(fixture(), indent=2, ensure_ascii=False) + "\n")
