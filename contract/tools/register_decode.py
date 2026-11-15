# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///
"""Computes contract/fixtures/register-decode.v1.json, independently of any collector.

Run from the repo root:
    uv run --script contract/tools/register_decode.py > contract/fixtures/register-decode.v1.json

Floats are decoded to the shortest decimal that parses back, at the register's
own width, to the same bits. The search is done in exact rational arithmetic
(the rounding interval of the bits), then checked against a `struct` round trip
and, for f64, against Python's own shortest `repr`.
"""

import json
import math
import struct
import sys
from dataclasses import dataclass
from decimal import Decimal
from fractions import Fraction
from pathlib import Path
from typing import Literal, cast

type FloatType = Literal["f32", "f64"]
type IntType = Literal["u16", "i16", "u32", "i32", "u64"]
type DataType = FloatType | IntType
type WordOrder = Literal["high_first", "low_first"]
type Json = None | bool | int | str | list[Json] | dict[str, Json]

CONTRACT = Path(__file__).resolve().parent.parent

DESCRIPTION_SENTENCES = (
    "Raw words, in register-address order as read from the meter, and the decimal string each must decode to.",
    "Computed independently of either collector by contract/tools/register_decode.py (Python struct, decimal and fractions).",
    "Integers are the raw integer divided by 10^decimals, exactly, with decimals places.",
    "Floats have no decimals: each decodes to the shortest decimal that, parsed at the register's own width (f32 or f64, round half to even), gives back the same bits: the fewest significant digits (at most 9 for f32, 17 for f64), and of the decimals with that many digits that do, the nearest the float's exact value, a tie going to the even last digit.",
    "The f32 is never widened to f64 first.",
    "It is written out in full, with no exponent, no trailing zeros after the point and no trailing point; negative zero is -0.",
    "profiles: entries of contract/profiles, by profile, profile_version and register key.",
    "types: each data type and word order, for an entry given inline.",
    "no_value: words that must decode to no value at all, with the error.",
    "Every implementation that decodes registers must give every value and refuse every no_value.",
    "Changing an expected value changes what is billed.",
)
DESCRIPTION = " ".join(DESCRIPTION_SENTENCES)

WIDTH: dict[DataType, int] = {
    "u16": 1,
    "i16": 1,
    "u32": 2,
    "i32": 2,
    "u64": 4,
    "f32": 2,
    "f64": 4,
}
DATA_TYPES: dict[str, DataType] = {t: t for t in WIDTH}
WORD_ORDERS: dict[str, WordOrder] = {
    "high_first": "high_first",
    "low_first": "low_first",
}
FLOAT_FORMAT: dict[FloatType, str] = {"f32": ">f", "f64": ">d"}
MAX_DIGITS: dict[FloatType, int] = {"f32": 9, "f64": 17}


@dataclass(frozen=True)
class Register:
    type: DataType
    word_order: WordOrder


@dataclass(frozen=True)
class Profile:
    name: str
    version: int
    registers: dict[str, Register]

    @staticmethod
    def load(path: Path) -> "Profile":
        raw: object = json.loads(path.read_text())  # pyright: ignore[reportAny] -- parsed below
        match raw:
            case {
                "profile": str(name),
                "version": int(version),
                "registers": list(entries),  # pyright: ignore[reportUnknownVariableType] -- cast below
            }:
                # A widening cast: the pattern leaves the items' type unknown.
                registers = dict(register_entry(e) for e in cast(list[object], entries))
                return Profile(name=name, version=version, registers=registers)
            case _:
                raise ValueError(f"{path}: not a profile with a version and registers")


def register_entry(entry: object) -> tuple[str, Register]:
    match entry:
        case {
            "key": str(key),
            "type": str(type_),
            "word_order": str(order),
        }:
            return key, Register(type=DATA_TYPES[type_], word_order=WORD_ORDERS[order])
        case _:
            raise ValueError(f"not a register entry: {entry}")


def words(data: bytes, order: WordOrder) -> list[int]:
    high_first = [
        int.from_bytes(data[i : i + 2], "big") for i in range(0, len(data), 2)
    ]
    return high_first if order == "high_first" else high_first[::-1]


def data_bytes(raw: list[int], order: WordOrder) -> bytes:
    high_first = raw if order == "high_first" else raw[::-1]
    return b"".join(w.to_bytes(2, "big") for w in high_first)


def float_words(type_: FloatType, order: WordOrder, bits: int) -> list[int]:
    return words(bits.to_bytes(WIDTH[type_] * 2, "big"), order)


def bits_of(type_: FloatType, x: float) -> int:
    """The bits of the float nearest x at the type's width."""
    return int.from_bytes(struct.pack(FLOAT_FORMAT[type_], x), "big")


def float_of(type_: FloatType, bits: int) -> float:
    x: object = struct.unpack(  # pyright: ignore[reportAny] -- narrowed below
        FLOAT_FORMAT[type_], bits.to_bytes(WIDTH[type_] * 2, "big")
    )[0]
    assert isinstance(x, float)
    return x


def round_trips(type_: FloatType, text: str, bits: int) -> bool:
    try:
        return bits_of(type_, float(text)) == bits
    except OverflowError:
        return False


def interval(type_: FloatType, bits: int) -> tuple[Fraction, Fraction, bool]:
    """Bounds of the decimals that round to these (finite, positive) bits, and whether
    the bounds themselves do: a tie rounds to the even mantissa."""
    x = Fraction(float_of(type_, bits))
    below = Fraction(float_of(type_, bits - 1))
    top = (0x7F7FFFFF if type_ == "f32" else 0x7FEFFFFFFFFFFFFF) == bits
    above = 2 * x - below if top else Fraction(float_of(type_, bits + 1))
    return (below + x) / 2, (x + above) / 2, bits % 2 == 0


def exponent10(x: Fraction) -> int:
    """The e with 10^e <= x < 10^(e+1), for x > 0."""
    e = math.floor(math.log10(x.numerator) - math.log10(x.denominator))
    return next(
        k
        for k in range(e - 2, e + 3)
        if Fraction(10) ** k <= x < Fraction(10) ** (k + 1)
    )


def shortest(type_: FloatType, bits: int) -> Decimal:
    """The shortest decimal naming these finite, positive, non-zero bits."""
    x = Fraction(float_of(type_, bits))
    low, high, closed = interval(type_, bits)

    def inside(d: Fraction) -> bool:
        return low < d < high or (closed and d in (low, high))

    for n in range(1, MAX_DIGITS[type_] + 1):
        scale = exponent10(x) - n + 1
        unit = Fraction(10) ** scale
        # round() on a Fraction breaks a tie to even, so the nearest comes first; a neighbour
        # can name the bits only where the interval is lopsided (at a power of two).
        nearest = round(x / unit)
        found = [k for k in (nearest, nearest - 1, nearest + 1) if inside(k * unit)]
        if found:
            return Decimal(found[0]).scaleb(scale)
    raise AssertionError(f"no {MAX_DIGITS[type_]}-digit decimal names {bits:x}")


def positional(d: Decimal) -> str:
    text = format(d.normalize(), "f")
    assert "e" not in text.lower()
    return text


def decode_float(type_: FloatType, bits: int) -> str:
    sign_bit = 1 << (WIDTH[type_] * 16 - 1)
    magnitude = bits & (sign_bit - 1)
    sign = "-" if bits & sign_bit else ""
    if magnitude == 0:
        return sign + "0"
    text = sign + positional(shortest(type_, magnitude))
    assert round_trips(type_, text, bits), f"{text} does not round-trip to {bits:x}"
    assert type_ == "f32" or Decimal(text) == Decimal(repr(float_of(type_, bits)))
    return text


def decode(
    type_: DataType, order: WordOrder, decimals: int | None, raw: list[int]
) -> str:
    assert len(raw) == WIDTH[type_]
    data = data_bytes(raw, order)
    match type_:
        case "f32" | "f64":
            assert decimals is None
            bits = int.from_bytes(data, "big")
            assert math.isfinite(float_of(type_, bits))
            return decode_float(type_, bits)
        case _:
            assert decimals is not None
            n = int.from_bytes(data, "big", signed=type_.startswith("i"))
            return format(Decimal(n).scaleb(-decimals), "f")


@dataclass(frozen=True)
class ProfileCase:
    profile: str
    key: str
    bits: int
    why: str


@dataclass(frozen=True)
class TypeCase:
    type: DataType
    word_order: WordOrder
    decimals: int | None
    raw: list[int]
    why: str


@dataclass(frozen=True)
class NoValue:
    profile: str
    key: str
    raw: list[int]
    error: str
    why: str


def f32(x: float) -> int:
    return bits_of("f32", x)


def f64(x: float) -> int:
    return bits_of("f64", x)


PROFILE_CASES = [
    ProfileCase("elite_440", "active_energy_import", 0, "zero"),
    ProfileCase("elite_440", "active_energy_import", f32(1234.5), "exact in f32"),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(0.1),
        "0.1 is not exact in f32: its exact value is 0.100000001490116..., and widened to f64 its shortest form would be 0.10000000149011612",
    ),
    ProfileCase("elite_440", "active_energy_import", f32(5.522), "an ordinary reading"),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(86761.985),
        "the nearest f32 is 86761.984375, and 86761.984 is the shortest that names it",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(123456.789),
        "the nearest f32 is 123456.7890625; widened to f64 its shortest form would be that",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(1000 + 2 / 1024),
        "all nine digits needed",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(1048576.25),
        "exactly between the two nearest 8-digit decimals: the tie goes to the even digit, down",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(1048576.75),
        "exactly between the two nearest 8-digit decimals: the tie goes to the even digit, up",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(2.0**24),
        "2^24, the last integer before f32 skips",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        f32(11703111.898),
        "above 2^23: the nearest f32 is 11703112",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        0x7F7FFFFF,
        "largest finite f32: every integer digit written out, no exponent; widened to f64 its shortest form would be 340282346638528860000000000000000000000",
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        0x0F800000,
        "2^-96, a power of two: the nearest 8-digit decimal (1.2621774e-29) does not round-trip, the one above it does, so 8 digits, not 9",
    ),
    ProfileCase("elite_440", "active_energy_import", 0x00800000, "smallest normal f32"),
    ProfileCase(
        "elite_440", "active_energy_import", 0x007FFFFF, "largest f32 subnormal"
    ),
    ProfileCase(
        "elite_440",
        "active_energy_import",
        0x00000001,
        "smallest f32 subnormal (1.40129846e-45 to nine digits): one digit names it",
    ),
    ProfileCase("elite_440", "active_energy_export", f32(-1.5), "negative"),
    ProfileCase(
        "elite_440",
        "active_energy_export",
        0x80000000,
        "negative zero keeps its sign: its bits differ from zero's",
    ),
    ProfileCase("elite_440", "active_energy_export", f32(-0.1), "negative, not exact"),
    ProfileCase("elite_500", "active_energy_import", 0, "zero"),
    ProfileCase(
        "elite_500", "active_energy_import", f64(1234.567), "f64 names it in 7 digits"
    ),
    ProfileCase(
        "elite_500", "active_energy_import", f64(0.1), "0.1 is not exact in f64 either"
    ),
    ProfileCase(
        "elite_500", "active_energy_import", f64(11703111.898), "an ordinary reading"
    ),
    ProfileCase(
        "elite_500",
        "active_energy_import",
        f64(0.1 + 0.2),
        "all seventeen digits needed",
    ),
    ProfileCase("elite_500", "active_energy_import", f64(2.0**53), "2^53"),
    ProfileCase(
        "elite_500",
        "active_energy_import",
        f64(1e21),
        "shortest form is exponent notation in JavaScript and Python",
    ),
    ProfileCase(
        "elite_500",
        "active_energy_import",
        f64(1e-7),
        "shortest form is exponent notation in JavaScript and Python",
    ),
    ProfileCase(
        "elite_500",
        "active_energy_import",
        0x7FEFFFFFFFFFFFFF,
        "largest finite f64: all 309 integer digits written out",
    ),
    ProfileCase(
        "elite_500",
        "active_energy_import",
        0x0060000000000000,
        "2^-1017, a power of two: the nearest 16-digit decimal does not round-trip, the one above it does, so 16 digits, not 17",
    ),
    ProfileCase(
        "elite_500", "active_energy_import", 0x0010000000000000, "smallest normal f64"
    ),
    ProfileCase(
        "elite_500", "active_energy_import", 0x000FFFFFFFFFFFFF, "largest f64 subnormal"
    ),
    ProfileCase(
        "elite_500",
        "active_energy_import",
        0x0000000000000001,
        "smallest f64 subnormal",
    ),
    ProfileCase(
        "elite_500", "reactive_energy_export", f64(-12.345678), "negative, kvarh"
    ),
    ProfileCase(
        "elite_500",
        "reactive_energy_export",
        0x8000000000000000,
        "negative zero keeps its sign",
    ),
]

TYPE_CASES = [
    TypeCase("u16", "high_first", 0, [65535], "largest u16"),
    TypeCase("u16", "high_first", 4, [5], "decimals shift the point"),
    TypeCase("i16", "high_first", 1, [65535], "all ones is -1"),
    TypeCase("i16", "high_first", 0, [32768], "smallest i16"),
    TypeCase("u32", "high_first", 2, [1, 57920], "high word first"),
    TypeCase("u32", "low_first", 2, [57920, 1], "low word first, same value"),
    TypeCase("u32", "low_first", 0, [0, 0], "zero"),
    TypeCase("u32", "high_first", 3, [0, 1000], "trailing zeros kept: decimals places"),
    TypeCase("i32", "low_first", 3, [0, 32768], "smallest i32"),
    TypeCase("i32", "high_first", 0, [65535, 65535], "all ones is -1"),
    TypeCase(
        "u64",
        "high_first",
        3,
        [65535, 65535, 65535, 65535],
        "largest u64: beyond 2^53, exact",
    ),
    TypeCase("u64", "low_first", 0, [1, 0, 0, 0], "low word first"),
    TypeCase("u64", "low_first", 0, [1, 0, 0, 32], "2^53 + 1, which no f64 holds"),
    TypeCase(
        "f32",
        "high_first",
        None,
        float_words("f32", "high_first", f32(0.25)),
        "high word first",
    ),
    TypeCase(
        "f32",
        "low_first",
        None,
        float_words("f32", "low_first", f32(0.25)),
        "low word first, same value",
    ),
    TypeCase(
        "f32",
        "high_first",
        None,
        float_words("f32", "high_first", f32(2.0)),
        "an integer: no point",
    ),
    TypeCase(
        "f32",
        "low_first",
        None,
        float_words("f32", "low_first", f32(0.3)),
        "not exact in f32",
    ),
    TypeCase(
        "f64",
        "high_first",
        None,
        float_words("f64", "high_first", f64(-0.125)),
        "high word first",
    ),
    TypeCase(
        "f64",
        "low_first",
        None,
        float_words("f64", "low_first", f64(-0.125)),
        "low word first, same value",
    ),
    TypeCase(
        "f64",
        "low_first",
        None,
        float_words("f64", "low_first", f64(0.1)),
        "not exact in f64",
    ),
]

NO_VALUE = [
    NoValue("elite_440", "active_energy_import", [0, 32704], "not_finite", "NaN"),
    NoValue(
        "elite_440",
        "active_energy_import",
        [0, 32640],
        "not_finite",
        "positive infinity",
    ),
    NoValue(
        "elite_440",
        "active_energy_import",
        [0, 65408],
        "not_finite",
        "negative infinity",
    ),
    NoValue("elite_500", "active_energy_import", [0, 0, 0, 32760], "not_finite", "NaN"),
    NoValue(
        "elite_500",
        "active_energy_import",
        [0, 0, 0, 65520],
        "not_finite",
        "negative infinity",
    ),
    NoValue(
        "elite_440",
        "active_energy_import",
        [1],
        "wrong_word_count",
        "one word for a two-word value",
    ),
    NoValue(
        "elite_500",
        "active_energy_import",
        [0, 0, 0, 0, 0],
        "wrong_word_count",
        "five words for a four-word value",
    ),
]


def profile_case(profiles: dict[str, Profile], case: ProfileCase) -> dict[str, Json]:
    profile = profiles[case.profile]
    register = profile.registers[case.key]
    assert register.type in ("f32", "f64")
    raw = float_words(register.type, register.word_order, case.bits)
    return {
        "profile": profile.name,
        "profile_version": profile.version,
        "register_key": case.key,
        "raw_words": list[Json](raw),
        "value": decode(register.type, register.word_order, None, raw),
        "why": case.why,
    }


def type_case(case: TypeCase) -> dict[str, Json]:
    decimals: dict[str, Json] = (
        {} if case.decimals is None else {"decimals": case.decimals}
    )
    return {
        "type": case.type,
        "word_order": case.word_order,
        **decimals,
        "raw_words": list[Json](case.raw),
        "value": decode(case.type, case.word_order, case.decimals, case.raw),
        "why": case.why,
    }


def no_value(profiles: dict[str, Profile], case: NoValue) -> dict[str, Json]:
    profile = profiles[case.profile]
    register = profile.registers[case.key]
    assert register.type in ("f32", "f64")
    if case.error == "not_finite":
        bits = int.from_bytes(data_bytes(case.raw, register.word_order), "big")
        assert not math.isfinite(float_of(register.type, bits))
    else:
        assert len(case.raw) != WIDTH[register.type]
    return {
        "profile": profile.name,
        "profile_version": profile.version,
        "register_key": case.key,
        "raw_words": list[Json](case.raw),
        "error": case.error,
        "why": case.why,
    }


def fixture() -> dict[str, Json]:
    profiles = {
        p.name: p
        for p in map(Profile.load, sorted((CONTRACT / "profiles").glob("*.json")))
    }
    return {
        "format": "register-decode/1",
        "description": DESCRIPTION,
        "profiles": [profile_case(profiles, c) for c in PROFILE_CASES],
        "types": [type_case(c) for c in TYPE_CASES],
        "no_value": [no_value(profiles, c) for c in NO_VALUE],
    }


if __name__ == "__main__":
    _ = sys.stdout.write(json.dumps(fixture(), indent=2) + "\n")
