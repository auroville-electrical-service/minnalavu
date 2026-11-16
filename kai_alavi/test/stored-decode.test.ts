import { describe, expect, test } from "bun:test";
import {
  decodeBlock,
  decodeDay,
  decodeInterval,
  decodeMask,
  decodeStamp,
  type Mask,
  type Profile,
  type Stamp,
  type Stored,
  supportedParameters,
} from "../src/index";
import { loadProfiles, loadStoredFixture } from "./contract";

const fixture = loadStoredFixture();
const profiles = loadProfiles();

type Copying = Profile & { readonly meter_clock: Stamp; readonly stored: Stored };

const profileAt = (c: { profile: string; profile_version: number }): Copying => {
  const p = profiles.get(c.profile);
  if (!p) throw new Error(`no profile ${c.profile}`);
  if (p.version !== c.profile_version) throw new Error(`${c.profile} is not at version ${c.profile_version}`);
  const { meter_clock, stored } = p;
  if (!meter_clock || !stored) throw new Error(`${c.profile} has no meter_clock or stored section`);
  return { ...p, meter_clock, stored };
};

const stampOf = (p: Copying, field: string): Stamp => {
  switch (field) {
    case "meter_clock":
      return p.meter_clock;
    case "history.stamp":
      return p.stored.history.stamp;
    case "snapshot.stamp":
      return p.stored.snapshot.stamp;
    case "load_survey.stamp":
      return p.stored.load_survey.stamp;
    default:
      throw new Error(`no stamp ${field}`);
  }
};

const maskOf = (p: Copying, field: string): { mask: Mask; named: readonly { bit: number; key: string }[] } => {
  const blockMask = (store: "history" | "snapshot") => {
    const { mask, registers } = p.stored[store];
    if (!mask) throw new Error(`${p.profile} ${store} has no mask`);
    return {
      mask,
      named: registers.flatMap((r) => (r.mask_bit === undefined ? [] : [{ bit: r.mask_bit, key: r.key }])),
    };
  };
  switch (field) {
    case "history.mask":
      return blockMask("history");
    case "snapshot.mask":
      return blockMask("snapshot");
    case "load_survey.mask":
      return {
        mask: p.stored.load_survey.mask,
        named: p.stored.load_survey.parameters.map((q) => ({ bit: q.number, key: q.key })),
      };
    default:
      throw new Error(`no mask ${field}`);
  }
};

const noValue = (fields: (f: string) => boolean) =>
  fixture.no_value.filter((c) => fields(c.field)).map((c) => [c.why, c] as const);

describe("decodeStamp", () => {
  test.each(fixture.stamps.map((c) => [c.why, c] as const))("%s", (_, c) => {
    expect(decodeStamp(stampOf(profileAt(c), c.field), c.raw_words)).toEqual({ ok: true, value: c.meter_time });
  });

  test.each(noValue((f) => f === "meter_clock" || f.endsWith(".stamp")))("no value: %s", (_, c) => {
    // A stamp has no other way to fail.
    expect(c.error).toBe("wrong_word_count");
    expect(decodeStamp(stampOf(profileAt(c), c.field), c.raw_words)).toEqual({ ok: false, error: "wrong_word_count" });
  });
});

describe("decodeMask", () => {
  test.each(fixture.masks.map((c) => [c.why, c] as const))("%s", (_, c) => {
    const p = profileAt(c);
    const { mask, named } = maskOf(p, c.field);
    const bits = decodeMask(mask, c.raw_words);
    if (!bits.ok) throw new Error(`refused: ${bits.error}`);
    const names = new Map(named.map((n) => [n.bit, n.key]));
    expect(bits.value.flatMap((bit) => (names.has(bit) ? [{ bit, register_key: names.get(bit) }] : []))).toEqual(
      c.named,
    );
    expect(bits.value.filter((bit) => !names.has(bit))).toEqual(c.unnamed);
    if (c.field === "load_survey.mask")
      expect(supportedParameters(p.stored.load_survey, bits.value).map((q) => q.key)).toEqual(
        c.named.map((n) => n.register_key),
      );
  });

  test.each(noValue((f) => f.endsWith(".mask")))("no value: %s", (_, c) => {
    expect(c.error).toBe("wrong_word_count");
    expect(decodeMask(maskOf(profileAt(c), c.field).mask, c.raw_words)).toEqual({
      ok: false,
      error: "wrong_word_count",
    });
  });
});

describe("decodeBlock", () => {
  test.each(fixture.blocks.map((c) => [c.why, c] as const))("%s", (_, c) => {
    const block = profileAt(c).stored[c.store];
    const read = { stamp: c.stamp_words, mask: c.mask_words ?? null, registers: c.registers };
    expect(decodeBlock(block, read)).toEqual({
      ok: true,
      value: {
        meterTime: c.meter_time,
        entries: c.entries.map((e) => ({ registerKey: e.register_key, value: e.value })),
        unsupported: c.unsupported,
        notFinite: c.not_finite,
      },
    });
  });

  test("mask words where the profile has none, or none where it has one, are refused", () => {
    const [masked, unmasked] = [fixture.blocks[0], fixture.blocks[3]];
    if (!masked?.mask_words || !unmasked || unmasked.mask_words) throw new Error("the fixture's blocks moved");
    const read = (c: typeof masked, mask: readonly number[] | null) =>
      decodeBlock(profileAt(c).stored[c.store], { stamp: c.stamp_words, mask, registers: c.registers });
    expect([read(masked, null), read(unmasked, [0])]).toEqual([
      { ok: false, error: "wrong_word_count" },
      { ok: false, error: "wrong_word_count" },
    ]);
  });
});

describe("decodeInterval", () => {
  test.each(noValue((f) => f === "load_survey.interval"))("no value: %s", (_, c) => {
    expect(decodeInterval(c.raw_words)).toEqual({ ok: false, error: c.error });
  });

  test("an interval that divides a day is its minutes", () => {
    expect([15, 30, 60].map((m) => decodeInterval([m]))).toEqual([15, 30, 60].map((value) => ({ ok: true, value })));
  });
});

describe("decodeDay", () => {
  test.each(fixture.load_survey.map((c) => [c.why, c] as const))("%s", (_, c) => {
    const p = profileAt(c);
    const read = {
      stamp: c.stamp_words,
      interval: c.interval_words,
      values: c.values_words,
      clock: c.clock_words ? { stamp: p.meter_clock, words: c.clock_words } : null,
    };
    // The day's own stamp is not in the case: its decode is the stamps cases'.
    const day = decodeStamp(p.stored.load_survey.stamp, c.stamp_words);
    if (!day.ok) throw new Error(`the day's stamp is refused: ${day.error}`);
    expect(decodeDay(p.stored.load_survey, read)).toEqual({
      ok: true,
      value: {
        meterTime: day.value,
        intervalS: c.interval_s,
        entries: c.entries.map((e) => ({ meterTime: e.meter_time, value: e.value })),
        notFinite: c.not_finite,
        notEnded: c.not_ended,
      },
    });
  });

  test.each(noValue((f) => f === "load_survey.values"))("no value: %s", (_, c) => {
    const p = profileAt(c);
    const read = { stamp: [0, 0], interval: [60], values: c.raw_words, clock: null };
    expect(decodeDay(p.stored.load_survey, read)).toEqual({ ok: false, error: c.error });
  });

  test("a day whose values do not fill its intervals is refused", () => {
    const [c] = fixture.load_survey;
    if (!c) throw new Error("the fixture has no load-survey case");
    const p = profileAt(c);
    const read = { stamp: c.stamp_words, interval: [30], values: c.values_words, clock: null };
    expect(decodeDay(p.stored.load_survey, read)).toEqual({ ok: false, error: "wrong_word_count" });
  });
});
