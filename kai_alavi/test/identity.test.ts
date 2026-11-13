import { describe, expect, test } from "bun:test";
import { err, identityReads, identityVerdict, type Outcome, ok, type ReadResult } from "../src/index";
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

const wire = (o: Outcome) => {
  switch (o.kind) {
    case "ok":
      return "ok";
    case "mismatch":
      expect(o.detail).not.toBe("");
      return "mismatch";
    case "read_failed":
      return {
        read_failed: o.failure.kind === "exception" ? { exception: o.failure.code } : { error: o.failure.reason },
      };
    default: {
      const unknown: never = o;
      return unknown;
    }
  }
};

const located = { table: "holding" as const, address: 0, source: "s", verified_on_device: null };
const words = (s: string, count: number) =>
  Array.from({ length: count }, (_, i) => (s.charCodeAt(2 * i) << 8) | (s.charCodeAt(2 * i + 1) || 0));

describe("identityReads", () => {
  test.each(Object.entries(fixture.reads))("%s reads what the fixture lists, in order", (name, reads) => {
    const listed = identityReads(identity(name)).map((r) => [r.check, r.table, r.address, r.count]);
    expect<unknown>(listed).toEqual(reads);
  });
});

describe("identityVerdict", () => {
  test.each(fixture.cases.map((c) => [`${c.profile}: ${c.why}`, c] as const))("%s", (_, c) => {
    const results = Object.fromEntries(Object.entries(c.results).map(([check, r]) => [check, result(r)]));
    const verdict = identityVerdict(identity(c.profile), results);
    expect(wire(verdict.outcome)).toEqual(c.verdict);
    expect(verdict.observed).toEqual(c.observed);
  });

  test("padding and surrounding spaces are trimmed; a NUL inside is not padding", () => {
    const product = { ...located, count: 4, accept: ["AB12"] };
    const judged = (s: string) =>
      identityVerdict({ product_code: product }, { product_code: ok(words(s, 4)) }).outcome.kind;
    expect(["AB12\0\0\0\0", " AB12   ", "AB12 \0\0\0"].map(judged)).toEqual(["ok", "ok", "ok"]);
    expect(["AB\x0012\0\0\0", "AB12\0  \0"].map(judged)).toEqual(["mismatch", "mismatch"]);
  });

  test("product codes compare as bytes against each code's UTF-8, as alavi compares them", () => {
    const product = { ...located, count: 2, accept: ["É1"] };
    const judged = (w: number[]) => identityVerdict({ product_code: product }, { product_code: ok(w) }).outcome.kind;
    expect(judged([0xc389, 0x3100])).toBe("ok");
    expect(judged([0xc931, 0x0000])).toBe("mismatch");
  });

  test("a serial is observed trimmed, and only when it is printable ASCII", () => {
    const serial = { ...located, count: 4 };
    const seen = (w: number[]) => {
      const { outcome, observed } = identityVerdict({ serial }, { serial: ok(w) });
      return [outcome.kind, observed.serial];
    };
    expect(seen(words(" SIM 1  ", 4))).toEqual(["ok", "SIM 1"]);
    expect(seen([0x5349, 0x4dc9, 0x3030, 0x3031])).toEqual(["mismatch", null]);
    expect(seen([0, 0, 0, 0])).toEqual(["mismatch", null]);
  });

  test("nothing is observed for checks the profile does not have", () => {
    expect(identityVerdict({}, {})).toEqual({
      outcome: { kind: "ok" },
      observed: { serial: null, product_code: null },
    });
  });

  test("a result missing for a listed read throws", () => {
    expect(() => identityVerdict(identity("elite_440"), {})).toThrow();
  });

  test("the first failing check decides", () => {
    const id = {
      product_code: { ...located, count: 1, accept: ["AB"] },
      serial: { ...located, address: 4, count: 1 },
      energy_unit: { ...located, address: 9, part: "word" as const, expect: 1, absent_ok: false },
    };
    const failed: ReadResult = err({ kind: "failed", reason: "timeout" });
    const kinds = (product: number[]) =>
      identityVerdict(id, { product_code: ok(product), serial: ok([0x5331]), energy_unit: failed }).outcome.kind;
    expect([kinds([0x4142]), kinds([0x4343])]).toEqual(["read_failed", "mismatch"]);
  });
});
