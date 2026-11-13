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

  test("an empty accepted product code is refused, as alavi refuses it", () => {
    const p = parsed("elite_440");
    if (!p.ok || !p.value.identity.product_code) throw new Error("elite_440 has no product code check");
    const product_code = { ...p.value.identity.product_code, accept: [""] };
    expect(parseProfile({ ...p.value, identity: { ...p.value.identity, product_code } }).ok).toBe(false);
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
    const text = JSON.stringify(p.value).replace(/"decimals":(\d+)/, '"decimals":$1.0');
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
});
