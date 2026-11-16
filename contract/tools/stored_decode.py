# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Computes contract/fixtures/stored-decode.v1.json, independently of any collector.

Run from the repo root:
    uv run --script contract/tools/stored_decode.py > contract/fixtures/stored-decode.v1.json

Reads each profile's meter_clock and stored sections, refusing any that breaks
the rules the store's catalog also enforces, and decodes stamps, masks,
history and snapshot blocks and load-survey days from words built here. The
values decode as register_decode.py decodes registers.
"""

import json
import math
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Literal, cast

from register_decode import (
    WORD_ORDERS,
    FloatType,
    WordOrder,
    bits_of,
    data_bytes,
    decode,
    float_of,
    float_words,
    words,
)

type Json = None | bool | int | str | list[Json] | dict[str, Json]
type Store = Literal["history", "snapshot", "load_survey"]
type Kind = Literal["cumulative", "interval", "demand", "instantaneous"]
type MaskType = Literal["u16", "u32", "u64"]

CONTRACT = Path(__file__).resolve().parent.parent

DESCRIPTION_SENTENCES = (
    "Raw words, in register-address order as read from the meter, and what each must decode to under a profile's meter_clock and stored sections.",
    "Computed independently of either collector by contract/tools/stored_decode.py, which decodes values as register_decode.py does.",
    "A stamp is an unsigned 32-bit count of seconds since the profile's epoch, in the stamp's word order, and decodes to a local date-time with no zone (YYYY-MM-DDTHH:MM:SS): the meter's own clock, never corrected.",
    "A mask is an unsigned integer in its word order; bit n set means the entry with mask_bit n (history, snapshot) or parameter number n (load survey) is supported. named lists the set bits the profile names, unnamed the set bits it does not, which are never read.",
    "blocks: a history or snapshot entry as read after its selector write: the stamp, the mask where the profile has one, and each register's words. Each register whose mask bit is clear is unsupported, whatever its words; each other register decodes to an entry, or is not_finite when its words are a NaN or an infinity, which is no value.",
    "load_survey: one parameter of one day, as read after both selector writes: the day's stamp, the interval in minutes and the day's values, two words each, from the first interval of the day. Interval i starts at the day's stamp plus i intervals, and that start is its meter_time.",
    "Where the meter's clock is given (the current day), an interval is an entry only when it has ended by that clock (its end no later than the clock); the rest are counted in not_ended, whatever their words.",
    "Values are decimal strings as in register-decode.v1.json, and their unit and kind are the profile entry's.",
    "no_value: words that must give no value at all, with the error.",
    "Every implementation that copies stored entries must give every result and refuse every no_value. Changing an expected value changes what may be billed.",
)
DESCRIPTION = " ".join(DESCRIPTION_SENTENCES)

STORES: tuple[Store, ...] = ("history", "snapshot", "load_survey")
KINDS: dict[str, Kind] = {
    k: k for k in ("cumulative", "interval", "demand", "instantaneous")
}
UNITS = frozenset(("Wh", "kWh", "varh", "kvarh", "V", "A", "Hz"))
MASK_TYPES: dict[str, MaskType] = {"u16": "u16", "u32": "u32", "u64": "u64"}
MASK_WIDTH: dict[MaskType, int] = {"u16": 1, "u32": 2, "u64": 4}
SELECTORS = frozenset(
    ("history", "snapshot", "load_survey_day", "load_survey_parameter")
)
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NAN32 = [65535, 65535]


@dataclass(frozen=True)
class Stamp:
    word_order: WordOrder
    epoch: datetime


@dataclass(frozen=True)
class Mask:
    type: MaskType
    word_order: WordOrder


@dataclass(frozen=True)
class Entry:
    key: str
    kind: Kind
    bit: int | None


@dataclass(frozen=True)
class Block:
    stamp: Stamp
    mask: Mask | None
    registers: tuple[Entry, ...]


@dataclass(frozen=True)
class Survey:
    stamp: Stamp
    mask: Mask
    values: FloatType
    values_order: WordOrder
    parameters: tuple[Entry, ...]


@dataclass(frozen=True)
class Profile:
    name: str
    version: int
    clock: Stamp
    history: Block
    snapshot: Block
    survey: Survey

    @staticmethod
    def load(path: Path) -> "Profile":
        raw: object = json.loads(path.read_text())  # pyright: ignore[reportAny] -- parsed below
        doc = fields(raw)
        stored = fields(doc.get("stored"))
        match doc:
            case {
                "profile": str(name),
                "version": int(version),
                "sources": ids,
                "meter_clock": clock,
            } if set(stored) == set(STORES):
                cite = cited(
                    frozenset(i for i in items(ids) if isinstance(i, str)), name
                )
                return Profile(
                    name=name,
                    version=version,
                    clock=stamp(cite(clock)),
                    history=block("history", stored["history"], cite),
                    snapshot=block("snapshot", stored["snapshot"], cite),
                    survey=survey_of(stored["load_survey"], cite),
                )
            case _:
                raise ValueError(
                    f"{path}: not a profile with a version, meter_clock and stored history, snapshot and load_survey"
                )

    def block(self, store: Store) -> Block:
        match store:
            case "history":
                return self.history
            case "snapshot":
                return self.snapshot
            case "load_survey":
                raise ValueError("the load survey is not a block")


def fields(raw: object) -> dict[str, object]:
    """A JSON object's fields, or none when it is not an object."""
    # A widening cast: json.loads gives str keys, and the values are checked by each pattern.
    return cast(dict[str, object], raw) if isinstance(raw, dict) else {}


def items(raw: object) -> list[object]:
    # A widening cast, as for fields.
    return cast(list[object], raw) if isinstance(raw, list) else []


def cited(sources: frozenset[str], profile: str) -> Callable[[object], object]:
    """Checks an entry names one of the profile's sources and an on-device date or null."""

    def check(entry: object) -> object:
        match fields(entry):
            case {"source": str(id_), "verified_on_device": None | str() as day} if (
                id_ in sources and (day is None or DATE.match(day))
            ):
                return entry
            case _:
                raise ValueError(
                    f"{profile}: not a cited entry (a source in sources, verified_on_device a date or null): {entry}"
                )

    return check


def stamp(entry: object) -> Stamp:
    match fields(entry):
        case {
            "table": "holding",
            "address": int(),
            "type": "u32",
            "word_order": str(order),
            "epoch": str(epoch),
        }:
            return Stamp(WORD_ORDERS[order], datetime.fromisoformat(epoch))
        case _:
            raise ValueError(f"not a stamp: {entry}")


def mask(entry: object) -> Mask:
    match fields(entry):
        case {"table": "holding", "address": int(), "type": "u16"}:
            return Mask("u16", "high_first")
        case {
            "table": "holding",
            "address": int(),
            "type": str(type_),
            "word_order": str(order),
        }:
            return Mask(MASK_TYPES[type_], WORD_ORDERS[order])
        case _:
            raise ValueError(f"not a mask: {entry}")


def count(entry: object) -> None:
    match fields(entry):
        case {"table": "holding", "address": int(), "type": "u16"}:
            return
        case _:
            raise ValueError(f"not a count register: {entry}")


def kind_of(store: Store, key: str, unit: str, kind: str) -> Kind:
    """The kind rules the catalog enforces: no cumulative quantity in the load
    survey, and no interval quantity in any other store."""
    if unit not in UNITS:
        raise ValueError(f"{store} {key}: unknown unit {unit}")
    found = KINDS[kind]
    if (found == "cumulative" and store == "load_survey") or (
        found == "interval" and store != "load_survey"
    ):
        raise ValueError(f"{store} {key}: kind {kind} is not allowed in {store}")
    return found


def register(store: Store, entry: object) -> Entry:
    match fields(entry):
        case {
            "key": str(key),
            "table": "holding",
            "address": int(),
            "type": "f32",
            "word_order": "low_first",
            "unit": str(unit),
            "kind": str(kind),
        }:
            bit = fields(entry).get("mask_bit")
            assert bit is None or isinstance(bit, int)
            return Entry(key, kind_of(store, key, unit, kind), bit)
        case _:
            raise ValueError(f"{store}: not a stored register: {entry}")


def unique(store: str, entries: list[Entry]) -> tuple[Entry, ...]:
    keys = [e.key for e in entries]
    bits = [e.bit for e in entries if e.bit is not None]
    if not entries:
        raise ValueError(f"{store}: lists no quantities")
    if len(set(keys)) != len(keys) or len(set(bits)) != len(bits):
        raise ValueError(f"{store}: a key or mask bit appears more than once")
    return tuple(entries)


def block(store: Store, raw: object, cite: Callable[[object], object]) -> Block:
    match fields(raw):
        case {
            "selector": str(selector),
            "available": available,
            "stamp": stamp_entry,
            "registers": entries,
        } if selector == store:
            count(cite(available))
            found = (
                None if "mask" not in fields(raw) else mask(cite(fields(raw)["mask"]))
            )
            registers = unique(
                store,
                [register(store, cite(e)) for e in items(entries)],
            )
            if (found is None) != all(r.bit is None for r in registers):
                raise ValueError(
                    f"{store}: mask_bit on every register exactly when there is a mask"
                )
            return Block(stamp(cite(stamp_entry)), found, registers)
        case _:
            raise ValueError(f"not a {store} section: {raw}")


def parameter(entry: object) -> Entry:
    match fields(entry):
        case {
            "number": int(n),
            "key": str(key),
            "unit": str(unit),
            "kind": str(kind),
        }:
            return Entry(key, kind_of("load_survey", key, unit, kind), n)
        case _:
            raise ValueError(f"load_survey: not a parameter: {entry}")


def survey_of(raw: object, cite: Callable[[object], object]) -> Survey:
    match fields(raw):
        case {
            "selectors": {"day": str(day), "parameter": str(param)},
            "available": available,
            "interval": {
                "table": "holding",
                "address": int(),
                "type": "u16",
                "unit": "min",
            } as interval,
            "stamp": stamp_entry,
            "mask": mask_entry,
            "values": {
                "table": "holding",
                "address": int(),
                "type": "f32",
                "word_order": str(order),
                "per_request": int(per_request),
            } as values,
            "parameters": entries,
        } if {day, param} <= SELECTORS and per_request > 0:
            count(cite(available))
            _ = cite(interval), cite(values)
            parameters = unique(
                "load_survey",
                [parameter(cite(e)) for e in items(entries)],
            )
            return Survey(
                stamp(cite(stamp_entry)),
                mask(cite(mask_entry)),
                "f32",
                WORD_ORDERS[order],
                parameters,
            )
        case _:
            raise ValueError(f"not a load_survey section: {raw}")


def stamp_words(s: Stamp, at: datetime) -> list[int]:
    seconds = (at - s.epoch) // timedelta(seconds=1)
    assert 0 <= seconds < 2**32
    return words(seconds.to_bytes(4, "big"), s.word_order)


def meter_time(s: Stamp, raw: list[int]) -> datetime:
    assert len(raw) == 2
    return s.epoch + timedelta(
        seconds=int.from_bytes(data_bytes(raw, s.word_order), "big")
    )


def iso(t: datetime) -> str:
    return t.isoformat(timespec="seconds")


def mask_words(m: Mask, bits: list[int]) -> list[int]:
    n = sum(1 << b for b in bits)
    return words(n.to_bytes(MASK_WIDTH[m.type] * 2, "big"), m.word_order)


def mask_bits(m: Mask, raw: list[int]) -> list[int]:
    assert len(raw) == MASK_WIDTH[m.type]
    n = int.from_bytes(data_bytes(raw, m.word_order), "big")
    return [b for b in range(MASK_WIDTH[m.type] * 16) if n >> b & 1]


def f32_words(x: float) -> list[int]:
    return float_words("f32", "low_first", bits_of("f32", x))


def value(raw: list[int], order: WordOrder = "low_first") -> str | None:
    """The value of an f32's words, or None for a NaN or an infinity."""
    bits = int.from_bytes(data_bytes(raw, order), "big")
    return (
        decode("f32", order, None, raw)
        if math.isfinite(float_of("f32", bits))
        else None
    )


@dataclass(frozen=True)
class StampCase:
    profile: str
    field: str
    at: datetime
    why: str


@dataclass(frozen=True)
class MaskCase:
    profile: str
    store: Store
    bits: list[int]
    why: str


@dataclass(frozen=True)
class BlockCase:
    profile: str
    store: Store
    at: datetime
    supported: list[str] | None
    values: dict[str, float]
    why: str


@dataclass(frozen=True)
class SurveyCase:
    profile: str
    number: int
    day: datetime
    minutes: int
    clock: datetime | None
    values: dict[int, float]
    why: str


@dataclass(frozen=True)
class NoValue:
    profile: str
    field: str
    raw: list[int]
    error: str
    why: str


T = datetime.fromisoformat

STAMP_CASES = [
    StampCase("elite_440", "meter_clock", T("1988-01-01T00:00:00"), "the epoch"),
    StampCase("elite_440", "meter_clock", T("2026-11-12T16:25:12"), "low word first"),
    StampCase(
        "elite_440",
        "meter_clock",
        T("2124-02-07T06:28:15"),
        "the last second a u32 holds",
    ),
    StampCase("elite_440", "history.stamp", T("2026-11-01T00:00:00"), "a billing date"),
    StampCase(
        "elite_440",
        "history.stamp",
        T("2026-10-01T00:05:23"),
        "a history minutes after midnight",
    ),
    StampCase(
        "elite_440", "snapshot.stamp", T("2026-11-14T00:00:00"), "a midnight snapshot"
    ),
    StampCase(
        "elite_440", "load_survey.stamp", T("2026-11-13T00:00:00"), "a load-survey day"
    ),
    StampCase("elite_500", "meter_clock", T("2000-01-01T00:00:00"), "the epoch"),
    StampCase("elite_500", "meter_clock", T("2026-11-13T10:41:03"), "high word first"),
    StampCase(
        "elite_500",
        "meter_clock",
        T("2136-02-07T06:28:15"),
        "the last second a u32 holds",
    ),
    StampCase("elite_500", "history.stamp", T("2026-11-01T00:00:00"), "a billing date"),
    StampCase(
        "elite_500",
        "history.stamp",
        T("2026-10-01T00:04:57"),
        "a history minutes after midnight",
    ),
    StampCase(
        "elite_500", "snapshot.stamp", T("2026-09-24T00:00:00"), "a midnight snapshot"
    ),
    StampCase(
        "elite_500", "load_survey.stamp", T("2026-11-13T00:00:00"), "a load-survey day"
    ),
]

MASK_CASES = [
    MaskCase("elite_440", "history", [0, 1, 4, 5, 6, 7, 8, 9], "a 445's energies"),
    MaskCase("elite_440", "snapshot", [0, 1, 8, 9, 10, 11], "a 446's energies"),
    MaskCase(
        "elite_440",
        "history",
        [0, 1, 2, 3],
        "fundamental energies, which no 445 or 446 has: unnamed",
    ),
    MaskCase(
        "elite_440",
        "load_survey",
        [0, 1, 8, 9, 19, 23, 27],
        "energies, average voltage and current, and frequency",
    ),
    MaskCase(
        "elite_440",
        "load_survey",
        [0, 24, 28, 29],
        "power factor and the pulse counters: unnamed",
    ),
    MaskCase("elite_500", "load_survey", [0, 1, 4, 5, 6], "net active (6) is unnamed"),
    MaskCase("elite_500", "load_survey", list(range(17)), "codes 0 to 16"),
    MaskCase("elite_500", "load_survey", [0, 63], "the top bit of the u64"),
]

E445 = [
    "active_energy_import",
    "active_energy_export",
    "reactive_energy_import_while_active_import",
    "reactive_energy_export_while_active_import",
    "reactive_energy_import_while_active_export",
    "reactive_energy_export_while_active_export",
]

BLOCK_CASES = [
    BlockCase(
        "elite_440",
        "history",
        T("2026-11-01T00:00:00"),
        E445,
        {
            "active_energy_import": 5.522,
            "active_energy_export": 47208.1,
            "reactive_energy_import_while_active_import": 0.0,
            "reactive_energy_export_while_active_import": 1.25,
            "reactive_energy_import_while_active_export": 312.5,
            "reactive_energy_export_while_active_export": 0.1,
        },
        "a 445's history: its two reactive registers outside the mask read NaN and are unsupported",
    ),
    BlockCase(
        "elite_440",
        "snapshot",
        T("2026-11-14T00:00:00"),
        E445,
        {
            "active_energy_import": 5.4,
            "active_energy_export": 47774.8,
            "reactive_energy_import_while_active_import": math.nan,
        },
        "a NaN under a supported bit is not_finite, not an entry",
    ),
    BlockCase(
        "elite_440",
        "history",
        T("2026-06-01T00:00:01"),
        ["active_energy_import"],
        {"active_energy_import": 0.07, "active_energy_export": 1.5},
        "a register outside the mask is unsupported even when its words are a number",
    ),
    BlockCase(
        "elite_500",
        "history",
        T("2026-11-01T00:00:00"),
        None,
        {
            "active_energy_import": 11600324.0,
            "active_energy_export": 86236.297,
            "reactive_energy_import": 53000.5,
        },
        "a 500's history has no mask in the profile: every NaN is not_finite",
    ),
    BlockCase(
        "elite_500",
        "snapshot",
        T("2026-11-13T00:00:00"),
        None,
        {
            "active_energy_import": 11699866.0,
            "active_energy_export": 86700.516,
            "active_energy_import_l1": -0.0,
        },
        "a snapshot; negative zero keeps its sign",
    ),
]

BLOCK_NO_VALUE = [
    NoValue(
        "elite_440", "meter_clock", [1], "wrong_word_count", "one word for a stamp"
    ),
    NoValue(
        "elite_500",
        "history.stamp",
        [0, 0, 0],
        "wrong_word_count",
        "three words for a stamp",
    ),
    NoValue(
        "elite_440",
        "history.mask",
        [0, 0],
        "wrong_word_count",
        "two words for a u16 mask",
    ),
    NoValue(
        "elite_500",
        "load_survey.mask",
        [0, 0x73],
        "wrong_word_count",
        "two words for a u64 mask",
    ),
    NoValue(
        "elite_440",
        "load_survey.interval",
        [0],
        "zero_interval",
        "an interval of 0 minutes",
    ),
    NoValue(
        "elite_440",
        "load_survey.interval",
        [7],
        "interval_not_dividing_a_day",
        "7 minutes does not divide a day",
    ),
    NoValue(
        "elite_440",
        "load_survey.values",
        [0, 0, 0],
        "wrong_word_count",
        "an odd number of words for f32 values",
    ),
]


def hourly(n: int, f: Callable[[int], float]) -> dict[int, float]:
    return {i: f(i) for i in range(n)}


SURVEY_CASES = [
    SurveyCase(
        "elite_440",
        1,
        T("2026-11-13T00:00:00"),
        60,
        None,
        hourly(24, lambda i: max(0.0, 4.62 - abs(i - 12) * 0.77)),
        "a past day's export per hour; zero intervals are entries",
    ),
    SurveyCase(
        "elite_440",
        27,
        T("2026-10-26T00:00:00"),
        30,
        None,
        {**hourly(48, lambda i: 49.69 + (i % 7) * 0.09), 5: math.nan},
        "frequency at 30 minutes; a NaN interval is not_finite",
    ),
    SurveyCase(
        "elite_440",
        0,
        T("2026-11-14T00:00:00"),
        60,
        T("2026-11-14T05:47:10"),
        hourly(5, lambda i: 0.25 * i),
        "the current day: by the meter's clock five intervals have ended; the rest read 0 and are not entries",
    ),
    SurveyCase(
        "elite_440",
        19,
        T("2026-11-14T00:00:00"),
        60,
        T("2026-11-14T03:00:00"),
        hourly(3, lambda i: 239.9 + i),
        "an interval ending exactly at the meter's clock has ended",
    ),
    SurveyCase(
        "elite_500",
        4,
        T("2026-11-13T00:00:00"),
        30,
        None,
        hourly(48, lambda i: 79.781 if i == 0 else 60.0 + i / 8),
        "a 500's import per half hour",
    ),
    SurveyCase(
        "elite_500",
        5,
        T("2026-11-14T00:00:00"),
        15,
        T("2026-11-14T00:31:00"),
        hourly(2, lambda i: 12.5 + i),
        "the current day at 15 minutes: two intervals have ended",
    ),
]


def find(profiles: dict[str, Profile], name: str) -> Profile:
    return profiles[name]


def stamp_field(p: Profile, field: str) -> Stamp:
    match field:
        case "meter_clock":
            return p.clock
        case "history.stamp":
            return p.history.stamp
        case "snapshot.stamp":
            return p.snapshot.stamp
        case "load_survey.stamp":
            return p.survey.stamp
        case _:
            raise ValueError(f"no stamp {field}")


def head(p: Profile) -> dict[str, Json]:
    return {"profile": p.name, "profile_version": p.version}


def stamp_case(profiles: dict[str, Profile], c: StampCase) -> dict[str, Json]:
    p = find(profiles, c.profile)
    s = stamp_field(p, c.field)
    raw = stamp_words(s, c.at)
    assert meter_time(s, raw) == c.at
    return {
        **head(p),
        "field": c.field,
        "raw_words": list[Json](raw),
        "meter_time": iso(c.at),
        "why": c.why,
    }


def store_mask(p: Profile, store: Store) -> tuple[Mask, tuple[Entry, ...]]:
    if store == "load_survey":
        return p.survey.mask, p.survey.parameters
    found = p.block(store)
    assert found.mask is not None
    return found.mask, found.registers


def mask_case(profiles: dict[str, Profile], c: MaskCase) -> dict[str, Json]:
    p = find(profiles, c.profile)
    m, entries = store_mask(p, c.store)
    raw = mask_words(m, c.bits)
    bits = mask_bits(m, raw)
    assert bits == c.bits
    names = {e.bit: e.key for e in entries}
    return {
        **head(p),
        "field": f"{c.store}.mask",
        "raw_words": list[Json](raw),
        "named": [{"bit": b, "register_key": names[b]} for b in bits if b in names],
        "unnamed": [b for b in bits if b not in names],
        "why": c.why,
    }


def block_case(profiles: dict[str, Profile], c: BlockCase) -> dict[str, Json]:
    p = find(profiles, c.profile)
    b = p.block(c.store)
    registers = {
        r.key: f32_words(c.values[r.key]) if r.key in c.values else NAN32
        for r in b.registers
    }
    supported = None if c.supported is None else set(c.supported)
    assert (supported is None) == (b.mask is None)
    mask_field: dict[str, Json] = {}
    if b.mask is not None and c.supported is not None:
        bits = [
            r.bit for r in b.registers if r.key in c.supported and r.bit is not None
        ]
        mask_field = {"mask_words": list[Json](mask_words(b.mask, bits))}
    unsupported = [
        r.key for r in b.registers if supported is not None and r.key not in supported
    ]
    decoded = {k: value(w) for k, w in registers.items() if k not in unsupported}
    return {
        **head(p),
        "store": c.store,
        "stamp_words": list[Json](stamp_words(b.stamp, c.at)),
        **mask_field,
        "registers": {k: list[Json](w) for k, w in registers.items()},
        "meter_time": iso(c.at),
        "entries": [
            {"register_key": k, "value": v} for k, v in decoded.items() if v is not None
        ],
        "unsupported": list[Json](unsupported),
        "not_finite": [k for k, v in decoded.items() if v is None],
        "why": c.why,
    }


def survey_case(profiles: dict[str, Profile], c: SurveyCase) -> dict[str, Json]:
    p = find(profiles, c.profile)
    s = p.survey
    key = next(e.key for e in s.parameters if e.bit == c.number)
    assert 1440 % c.minutes == 0
    step = timedelta(minutes=c.minutes)
    n = 1440 // c.minutes
    raw = [w for i in range(n) for w in f32_words(c.values.get(i, 0.0))]
    ended = (
        n
        if c.clock is None
        else sum(1 for i in range(n) if c.day + (i + 1) * step <= c.clock)
    )
    decoded = [
        (iso(c.day + i * step), value(raw[2 * i : 2 * i + 2], s.values_order))
        for i in range(ended)
    ]
    clock: dict[str, Json] = (
        {}
        if c.clock is None
        else {"clock_words": list[Json](stamp_words(p.clock, c.clock))}
    )
    return {
        **head(p),
        "parameter": c.number,
        "register_key": key,
        "stamp_words": list[Json](stamp_words(s.stamp, c.day)),
        "interval_words": [c.minutes],
        **clock,
        "values_words": list[Json](raw),
        "interval_s": c.minutes * 60,
        "entries": [{"meter_time": t, "value": v} for t, v in decoded if v is not None],
        "not_finite": [t for t, v in decoded if v is None],
        "not_ended": n - ended,
        "why": c.why,
    }


def width(p: Profile, field: str) -> int:
    match field.split("."):
        case [store, "mask"]:
            return MASK_WIDTH[store_mask(p, cast(Store, store))[0].type]
        case ["load_survey", "interval"]:
            return 1
        case _:
            _ = stamp_field(p, field)
            return 2


def refused(p: Profile, c: NoValue) -> bool:
    match c.error:
        case "wrong_word_count" if c.field == "load_survey.values":
            return len(c.raw) % 2 == 1
        case "wrong_word_count":
            return len(c.raw) != width(p, c.field)
        case "zero_interval":
            return c.field == "load_survey.interval" and c.raw == [0]
        case "interval_not_dividing_a_day":
            return (
                c.field == "load_survey.interval"
                and c.raw[0] > 0
                and 1440 % c.raw[0] != 0
            )
        case _:
            return False


def no_value(profiles: dict[str, Profile], c: NoValue) -> dict[str, Json]:
    p = find(profiles, c.profile)
    assert refused(p, c), f"{c.why}: not refused as {c.error}"
    return {
        **head(p),
        "field": c.field,
        "raw_words": list[Json](c.raw),
        "error": c.error,
        "why": c.why,
    }


def fixture() -> dict[str, Json]:
    profiles = {
        p.name: p
        for p in map(Profile.load, sorted((CONTRACT / "profiles").glob("*.json")))
    }
    return {
        "format": "stored-decode/1",
        "description": DESCRIPTION,
        "stamps": [stamp_case(profiles, c) for c in STAMP_CASES],
        "masks": [mask_case(profiles, c) for c in MASK_CASES],
        "blocks": [block_case(profiles, c) for c in BLOCK_CASES],
        "load_survey": [survey_case(profiles, c) for c in SURVEY_CASES],
        "no_value": [no_value(profiles, c) for c in BLOCK_NO_VALUE],
    }


if __name__ == "__main__":
    _ = sys.stdout.write(json.dumps(fixture(), indent=2) + "\n")
