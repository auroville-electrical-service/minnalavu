import { describe, expect, test } from "bun:test";
import { err, identityReads, identityVerdict, ok, type ReadResult, type Verdict } from "../src/index";
import { loadIdentityFixture, loadProfiles } from "./contract";

const fixture = loadIdentityFixture();
const profiles = loadProfiles();

const identity = (name: string) => {
  const profile = profiles.get(name);
  if (!profile) throw new Error(`no profile ${name}`);
  return profile.identity;
};

const result = (r: { words: number[] } | { exception: number } | { error: string }): ReadResult =>
  "words" in r
    ? ok(r.words)
    : "exception" in r
      ? err({ kind: "exception", code: r.exception })
      : err({ kind: "failed", reason: r.error });

const wire = (v: Verdict) => {
  switch (v.kind) {
    case "ok":
      return "ok";
    case "mismatch":
      expect(v.detail).not.toBe("");
      return "mismatch";
    case "read_failed":
      return {
        read_failed: v.failure.kind === "exception" ? { exception: v.failure.code } : { error: v.failure.reason },
      };
    default: {
      const unknown: never = v;
      return unknown;
    }
  }
};

describe("identityReads", () => {
  test.each(Object.entries(fixture.reads))("%s reads what the fixture lists, in order", (name, reads) => {
    const listed = identityReads(identity(name)).map((r) => [r.check, r.table, r.address, r.count]);
    expect<unknown>(listed).toEqual(reads);
  });
});

describe("identityVerdict", () => {
  test.each(fixture.cases.map((c) => [`${c.profile}: ${c.why}`, c] as const))("%s", (_, c) => {
    const results = Object.fromEntries(Object.entries(c.results).map(([check, r]) => [check, result(r)]));
    expect(wire(identityVerdict(identity(c.profile), results))).toEqual(c.verdict);
  });

  test("padding and surrounding spaces are trimmed; a NUL inside is not padding", () => {
    const product = {
      table: "holding" as const,
      address: 0,
      count: 4,
      accept: ["AB12"],
      source: "s",
    };
    const words = (s: string) =>
      Array.from({ length: 4 }, (_, i) => (s.charCodeAt(2 * i) << 8) | (s.charCodeAt(2 * i + 1) || 0));
    const judged = (s: string) => identityVerdict({ product_code: product }, { product_code: ok(words(s)) }).kind;
    expect(["AB12\0\0\0\0", " AB12   ", "AB12 \0\0\0"].map(judged)).toEqual(["ok", "ok", "ok"]);
    expect(["AB\x0012\0\0\0", "AB12\0  \0"].map(judged)).toEqual(["mismatch", "mismatch"]);
  });

  test("product codes compare as bytes against each code's UTF-8, as alavi compares them", () => {
    const product = {
      table: "holding" as const,
      address: 0,
      count: 2,
      accept: ["É1"],
      source: "s",
    };
    const judged = (words: number[]) => identityVerdict({ product_code: product }, { product_code: ok(words) }).kind;
    expect(judged([0xc389, 0x3100])).toBe("ok");
    expect(judged([0xc931, 0x0000])).toBe("mismatch");
  });

  test("a result missing for a listed read throws", () => {
    expect(() => identityVerdict(identity("elite_440"), {})).toThrow();
  });

  test("the first failing check decides", () => {
    const id = {
      product_code: { table: "holding" as const, address: 0, count: 1, accept: ["AB"], source: "s" },
      energy_unit: {
        table: "holding" as const,
        address: 9,
        part: "word" as const,
        expect: 1,
        absent_ok: false,
        source: "s",
      },
    };
    const failed: ReadResult = err({ kind: "failed", reason: "timeout" });
    const kinds = (product: number[]) => identityVerdict(id, { product_code: ok(product), energy_unit: failed }).kind;
    expect([kinds([0x4142]), kinds([0x4343])]).toEqual(["read_failed", "mismatch"]);
  });
});
