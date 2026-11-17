import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseProfile } from "../src/index";
import { contract } from "./contract";

const parsed = (name: string) =>
  parseProfile(JSON.parse(readFileSync(join(contract, "profiles", `${name}.json`), "utf8")));

describe("parseProfile", () => {
  test("both contract profiles parse", () => {
    expect([parsed("elite_440").ok, parsed("elite_500").ok]).toEqual([true, true]);
  });

  test("an accepted product code must be non-empty printable ASCII, as alavi requires", () => {
    const p = parsed("elite_440");
    if (!p.ok || !p.value.identity.product_code) throw new Error("elite_440 has no product code check");
    const { value } = p;
    const product = value.identity.product_code;
    const parsedWith = (code: string) =>
      parseProfile({ ...value, identity: { ...value.identity, product_code: { ...product, accept: [code] } } });
    expect(["", "ELITE\u00b7440", "ELITE\t440", "ELITE 440"].map((c) => parsedWith(c).ok)).toEqual([
      false,
      false,
      false,
      true,
    ]);
    expect(parsedWith("ELITE\u00b7440")).toMatchObject({ ok: false, error: expect.stringContaining("accept") });
  });

  test("a source must be an ID listed in sources, once", () => {
    const p = parsed("elite_440");
    if (!p.ok) throw new Error("elite_440 does not parse");
    const [first, ...rest] = p.value.registers;
    if (!first) throw new Error("elite_440 has no registers");
    const withSources = (sources: string[]) => parseProfile({ ...p.value, sources }).ok;
    const withRegister = (source: string) =>
      parseProfile({ ...p.value, registers: [{ ...first, source }, ...rest] }).ok;
    expect([withSources(["elite_440-a", "elite_440-a"]), withSources(["Vendor map"]), withRegister("other")]).toEqual([
      false,
      false,
      false,
    ]);
  });

  test("firmware names cite a listed source, and take no accept or expect", () => {
    const p = parsed("elite_440");
    if (!p.ok) throw new Error("elite_440 does not parse");
    const { value } = p;
    const names = value.firmware;
    if (!names) throw new Error("elite_440 has no firmware section");
    const withSoftware = (extra: object) =>
      parseProfile({ ...value, firmware: { ...names, software: { ...names.software, ...extra } } }).ok;
    expect([
      withSoftware({}),
      withSoftware({ source: "other" }),
      withSoftware({ accept: ["X"] }),
      withSoftware({ expect: 1 }),
      withSoftware({ type: "u16" }),
    ]).toEqual([true, false, false, false, false]);
    const { firmware_2: _, ...missing } = names;
    expect(parseProfile({ ...value, firmware: missing }).ok).toBe(false);
    const { firmware: __, ...without } = value;
    const parsedWithout = parseProfile(without);
    expect(parsedWithout.ok && parsedWithout.value.firmware).toBeUndefined();
  });

  test("verified_on_device is null or a date", () => {
    const p = parsed("elite_440");
    if (!p.ok) throw new Error("elite_440 does not parse");
    const [first, ...rest] = p.value.registers;
    if (!first) throw new Error("elite_440 has no registers");
    const verified = (on: unknown) =>
      parseProfile({ ...p.value, registers: [{ ...first, verified_on_device: on }, ...rest] }).ok;
    expect([verified("2026-11-14"), verified(true), verified("14/11/2026")]).toEqual([true, false, false]);
  });

  test("an integer written with a fraction passes, as JSON.parse cannot tell 199.0 from 199", () => {
    const p = parsed("elite_440");
    if (!p.ok) throw new Error("elite_440 does not parse");
    const text = JSON.stringify(p.value).replace(/"address":(\d+)/, '"address":$1.0');
    expect(text).toContain(".0,");
    expect(parseProfile(JSON.parse(text)).ok).toBe(true);
  });

  test("an empty profile name, or a model that is not a string, is refused", () => {
    const p = parsed("elite_440");
    if (!p.ok) throw new Error("elite_440 does not parse");
    expect([parseProfile({ ...p.value, profile: "" }).ok, parseProfile({ ...p.value, models: [1] }).ok]).toEqual([
      false,
      false,
    ]);
  });

  test("a profile has a version from 1 to 2^53 - 1", () => {
    const p = parsed("elite_440");
    if (!p.ok) throw new Error("elite_440 does not parse");
    const { version: _, ...without } = p.value;
    const versioned = (version: unknown) => parseProfile({ ...p.value, version }).ok;
    expect([versioned(3), versioned(0), versioned(2 ** 53), versioned("1"), versioned(1.5)]).toEqual([
      true,
      false,
      false,
      false,
      false,
    ]);
    expect(parseProfile(without).ok).toBe(false);
  });

  const withRegister = (extra: object, drop?: string) => {
    const p = parsed("elite_440");
    if (!p.ok) throw new Error("elite_440 does not parse");
    const [first, ...rest] = p.value.registers;
    if (!first) throw new Error("elite_440 has no registers");
    const entry = Object.fromEntries(Object.entries({ ...first, ...extra }).filter(([k]) => k !== drop));
    return parseProfile({ ...p.value, registers: [entry, ...rest] });
  };

  test("every register has a kind", () => {
    expect([
      withRegister({ kind: "interval" }).ok,
      withRegister({ kind: "net" }).ok,
      withRegister({}, "kind").ok,
    ]).toEqual([true, false, false]);
  });

  test("an integer register has decimals, a float none", () => {
    expect(withRegister({ type: "u32", decimals: 3 })).toMatchObject({ ok: true });
    expect(withRegister({ type: "u32" }).ok).toBe(false);
    expect(withRegister({ type: "f64" })).toMatchObject({ ok: true });
    expect(withRegister({ type: "f32", decimals: 3 })).toMatchObject({
      ok: false,
      error: expect.stringContaining("decimals is for integer registers"),
    });
  });
});

describe("parseProfile stored sections", () => {
  const p = parsed("elite_440");
  if (!p.ok || !p.value.stored) throw new Error("elite_440 has no stored section");
  const { value } = p;
  const { stored } = p.value;
  const [first, ...rest] = stored.history.registers;
  const [parameter, ...others] = stored.load_survey.parameters;
  if (!first || !parameter) throw new Error("elite_440's stored sections are empty");
  const withHistory = (changes: object) =>
    parseProfile({ ...value, stored: { ...stored, history: { ...stored.history, ...changes } } });
  const withParameter = (changes: object) =>
    parseProfile({
      ...value,
      stored: {
        ...stored,
        load_survey: { ...stored.load_survey, parameters: [{ ...parameter, ...changes }, ...others] },
      },
    });

  test("both contract profiles have a meter clock and every store", () => {
    const both = [parsed("elite_440"), parsed("elite_500")].map((r) =>
      r.ok ? [r.value.meter_clock !== undefined, Object.keys(r.value.stored ?? {}).sort()] : null,
    );
    expect(both).toEqual([
      [true, ["history", "load_survey", "snapshot"]],
      [true, ["history", "load_survey", "snapshot"]],
    ]);
  });

  test("the catalog's kind rules: no cumulative load-survey quantity, no per-interval one elsewhere", () => {
    expect([
      withParameter({ kind: "cumulative" }).ok,
      withParameter({ kind: "demand" }).ok,
      withHistory({ registers: [{ ...first, kind: "interval" }, ...rest] }).ok,
    ]).toEqual([false, true, false]);
  });

  test("a mask_bit on every register exactly when there is a mask, each bit once", () => {
    const { mask_bit: _bit, ...unmasked } = first;
    const { mask: _mask, ...noMask } = stored.history;
    expect([
      withHistory({ registers: [unmasked, ...rest] }).ok,
      parseProfile({ ...value, stored: { ...stored, history: noMask } }).ok,
      withHistory({ registers: [{ ...first, mask_bit: rest[0]?.mask_bit }, ...rest] }).ok,
    ]).toEqual([false, false, false]);
  });

  test("a stored entry cites a listed source, and names its selector, never an address", () => {
    expect([
      withParameter({ source: "other" }).ok,
      withHistory({ selector: "snapshot" }).ok,
      withHistory({ selector: 520 }).ok,
      parseProfile({ ...value, meter_clock: { ...value.meter_clock, epoch: "1988-02-30T00:00:00" } }).ok,
    ]).toEqual([false, false, false, false]);
  });

  test("a 500's load survey requires its logger type and energy storage type; each is a cited u16", () => {
    const p500 = parsed("elite_500");
    if (!p500.ok || !p500.value.stored) throw new Error("elite_500 has no stored section");
    const survey = p500.value.stored.load_survey;
    const [logger, storage] = survey.requires ?? [];
    if (!logger || !storage) throw new Error("elite_500's load survey requires nothing");
    const withRequires = (requires: object[]) =>
      parseProfile({
        ...p500.value,
        stored: { ...p500.value.stored, load_survey: { ...survey, requires } },
      }).ok;
    expect([
      (survey.requires ?? []).map((r) => [r.key, r.address, r.value]),
      stored.load_survey.requires,
      withRequires([{ ...logger, type: "u32" }, storage]),
      withRequires([{ ...logger, value: 0x10000 }, storage]),
      withRequires([logger, { ...storage, key: logger.key }]),
      withRequires([{ ...logger, source: "other" }, storage]),
    ]).toEqual([
      [
        ["logger_type", 5001, 2],
        ["energy_storage_type", 1844, 0],
      ],
      undefined,
      false,
      false,
      false,
      false,
    ]);
  });
});
