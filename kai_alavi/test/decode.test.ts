import { describe, expect, test } from "bun:test";
import { decodeValue, findRegister, type Register } from "../src/index";
import { loadDecodeFixture, loadProfiles } from "./contract";

const fixture = loadDecodeFixture();
const profiles = loadProfiles();

const register = (c: { profile: string; register_key: string }): Register => {
  const profile = profiles.get(c.profile);
  if (!profile) throw new Error(`no profile ${c.profile}`);
  const found = findRegister(profile, c.register_key);
  if (!found.ok) throw new Error(`no register ${c.register_key} in ${c.profile}`);
  return found.value;
};

describe("decodeValue", () => {
  describe("contract/fixtures/register-decode.v1.json", () => {
    test.each(fixture.profiles.map((c) => [`${c.profile} ${c.register_key}: ${c.why}`, c] as const))("%s", (_, c) => {
      const r = register(c);
      expect(decodeValue(r, c.raw_words)).toEqual({ ok: true, value: c.value });
      expect<string>(r.unit).toBe(c.unit);
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
});
