import { describe, expect, test } from "bun:test";
import { decodeValue, findRegister, type Register } from "../src/index";
import { loadDecodeFixture, loadProfiles } from "./contract";

const fixture = loadDecodeFixture();
const profiles = loadProfiles();

const register = (c: { profile: string; profile_version: number; register_key: string }): Register => {
  const profile = profiles.get(c.profile);
  if (!profile) throw new Error(`no profile ${c.profile}`);
  if (profile.version !== c.profile_version) throw new Error(`${c.profile} is not at version ${c.profile_version}`);
  const found = findRegister(profile, c.register_key);
  if (!found.ok) throw new Error(`no register ${c.register_key} in ${c.profile}`);
  return found.value;
};

type Width = "f32" | "f64";

const wordsOf = (width: Width, bits: bigint): number[] => {
  const count = width === "f32" ? 2 : 4;
  return Array.from({ length: count }, (_, i) => Number((bits >> BigInt(16 * (count - 1 - i))) & 0xffffn));
};

const bitsOf = (width: Width, x: number): bigint => {
  const view = new DataView(new ArrayBuffer(8));
  if (width === "f64") {
    view.setFloat64(0, x);
    return view.getBigUint64(0);
  }
  view.setFloat32(0, x);
  return BigInt(view.getUint32(0));
};

// The parse back goes through f64 for f32: double rounding could mislead it, but only for a
// decimal within 2^-53 of an f32 midpoint.
const parsedBits = (width: Width, text: string): bigint => bitsOf(width, Number(text));

// The decimals of one fewer significant digit either side of `text`: if any shorter decimal named
// the same bits, one of these would.
const shorter = (text: string): string[] => {
  const [whole = "", fraction = ""] = text.split(".");
  const significant = (whole + fraction).replace(/^0+/, "");
  const trailing = significant.length - significant.replace(/0+$/, "").length;
  if (significant.length - trailing < 2) return [];
  const unit = 10n ** BigInt(trailing + 1);
  const down = (BigInt(whole + fraction) / unit) * unit;
  return [down, down + unit].map((k) => `${k}e-${fraction.length}`);
};

const random32 = (): bigint => BigInt(Math.floor(Math.random() * 2 ** 32));

// A random finite, positive, non-zero float, below the largest, whose shorter neighbours overflow.
const randomBits = (width: Width): bigint => {
  const top = width === "f32" ? 0x7f000000n : 0x7fe0000000000000n;
  return 1n + (((random32() << 32n) | random32()) % top);
};

// JavaScript's own shortest form of an f64, written out in full.
const positionalString = (x: number): string => {
  const [mantissa = "", exponent = "0"] = String(x).split("e");
  const [whole = "", fraction = ""] = mantissa.split(".");
  const digits = whole + fraction;
  const point = whole.length + Number(exponent);
  const padded = point <= 0 ? "0".repeat(1 - point) + digits : digits.padEnd(point, "0");
  const at = Math.max(point, 1);
  const rest = padded.slice(at).replace(/0+$/, "");
  return rest === "" ? padded.slice(0, at) : `${padded.slice(0, at)}.${rest}`;
};

describe("decodeValue", () => {
  describe("contract/fixtures/register-decode.v1.json", () => {
    test.each(fixture.profiles.map((c) => [`${c.profile} ${c.register_key}: ${c.why}`, c] as const))("%s", (_, c) => {
      expect(decodeValue(register(c), c.raw_words)).toEqual({ ok: true, value: c.value });
    });

    test.each(fixture.types.map((c) => [`${c.type} ${c.word_order}: ${c.why}`, c] as const))("%s", (_, c) => {
      expect(decodeValue(c, c.raw_words)).toEqual({ ok: true, value: c.value });
    });

    test.each(fixture.no_value.map((c) => [`${c.profile} ${c.register_key}: ${c.why}`, c] as const))("%s", (_, c) => {
      expect(decodeValue(register(c), c.raw_words)).toEqual({ ok: false, error: c.error });
    });
  });

  describe("the value is never a JSON number's precision", () => {
    test("u64 beyond 2^53 is exact", () => {
      const r = { type: "u64", word_order: "high_first", decimals: 0 } as const;
      expect(decodeValue(r, [0x0020, 0, 0, 1])).toEqual({ ok: true, value: "9007199254740993" });
    });
  });

  describe("a float decodes to a decimal that gives back its bits, and none shorter does", () => {
    test.each(["f32", "f64"] as const)("%s, at random", (width) => {
      const failures = Array.from({ length: 2000 }, () => randomBits(width)).flatMap((bits) => {
        const decoded = decodeValue({ type: width, word_order: "high_first" }, wordsOf(width, bits));
        if (!decoded.ok) return [`${bits.toString(16)}: ${decoded.error}`];
        const short = shorter(decoded.value).filter((s) => parsedBits(width, s) === bits);
        return parsedBits(width, decoded.value) === bits && short.length === 0
          ? []
          : [`${bits.toString(16)}: ${decoded.value} (shorter: ${short.join(", ")})`];
      });
      expect(failures).toEqual([]);
    });

    test("an f64's is JavaScript's own shortest form, written out in full", () => {
      const failures = Array.from({ length: 2000 }, () => randomBits("f64")).flatMap((bits) => {
        const view = new DataView(new ArrayBuffer(8));
        view.setBigUint64(0, bits);
        const expected = positionalString(view.getFloat64(0));
        const decoded = decodeValue({ type: "f64", word_order: "high_first" }, wordsOf("f64", bits));
        return decoded.ok && decoded.value === expected ? [] : [`${bits.toString(16)}: ${expected}`];
      });
      expect(failures).toEqual([]);
    });
  });
});
