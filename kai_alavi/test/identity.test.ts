import { describe, expect, test } from "bun:test";
import {
  err,
  type IdentityRequest,
  identityReads,
  identityRequests,
  identityVerdict,
  type Outcome,
  ok,
  type ReadResult,
  type Results,
  splitReply,
} from "../src/index";
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

describe("identityRequests", () => {
  test.each(Object.entries(fixture.requests))("%s merges its reads into the fixture's requests", (name, requests) => {
    const made = identityRequests(identity(name)).map((r) => [
      r.table,
      r.address,
      r.count,
      r.reads.map((x) => x.check),
    ]);
    expect<unknown>(made).toEqual(requests);
  });

  test("an empty identity makes no request", () => {
    expect(identityRequests({})).toEqual([]);
  });

  test("15 registers between reads share a request; 16 part them, requests following their first read", () => {
    const id = (serialAt: number) => ({
      product_code: { ...located, address: serialAt + 4, count: 6, accept: ["AB"] },
      serial: { ...located, address: serialAt, count: 4 },
      energy_unit: { ...located, address: 0, part: "word" as const, expect: 1, absent_ok: false },
    });
    const shape = (serialAt: number) => identityRequests(id(serialAt)).map((r) => [r.address, r.count]);
    expect(shape(16)).toEqual([[0, 26]]);
    expect(shape(17)).toEqual([
      [17, 10],
      [0, 1],
    ]);
  });

  test("a request never passes 125 registers, nor joins reads in another table", () => {
    const id = (count: number, table: "holding" | "input" = "holding") => ({
      serial: { ...located, count: 110 },
      product_code: { ...located, table, address: 110, count, accept: ["AB"] },
    });
    const shape = (i: ReturnType<typeof id>) => identityRequests(i).map((r) => [r.table, r.address, r.count]);
    expect(shape(id(15))).toEqual([["holding", 0, 125]]);
    expect(shape(id(16))).toEqual([
      ["holding", 110, 16],
      ["holding", 0, 110],
    ]);
    expect(shape(id(6, "input"))).toEqual([
      ["input", 110, 6],
      ["holding", 0, 110],
    ]);
  });
});

describe("splitReply", () => {
  test("each read gets its own words out of a merged reply", () => {
    const request: IdentityRequest = {
      table: "holding",
      address: 10,
      count: 8,
      reads: [
        { check: "product_code", table: "holding", address: 15, count: 3 },
        { check: "serial", table: "holding", address: 10, count: 2 },
      ],
    };
    expect(splitReply(request, [1, 2, 3, 4, 5, 6, 7, 8])).toEqual({ product_code: ok([6, 7, 8]), serial: ok([1, 2]) });
  });

  // A meter's reply to each request, its other registers 0xFFFF; or, where any of its reads fails
  // alone, those reads made alone, as `alavi` falls back to them.
  const replied = (request: IdentityRequest, alone: Results): Results => {
    const own = request.reads.map((r) => ({ r, result: alone[r.check] }));
    if (!own.every(({ result }) => result?.ok))
      return Object.fromEntries(own.map(({ r, result }) => [r.check, result]));
    const words = own.reduce<readonly number[]>((words, { r, result }) => {
      const value = result?.ok ? result.value : [];
      const at = r.address - request.address;
      return [...words.slice(0, at), ...value, ...words.slice(at + value.length)];
    }, Array(request.count).fill(0xffff));
    return splitReply(request, words);
  };

  test.each(fixture.cases.map((c) => [`${c.profile}: ${c.why}`, c] as const))(
    "a merged reply gives each read its words alone, and the same verdict: %s",
    (_, c) => {
      const id = identity(c.profile);
      const alone: Results = Object.fromEntries(Object.entries(c.results).map(([check, r]) => [check, result(r)]));
      const merged = Object.assign({}, ...identityRequests(id).map((r) => replied(r, alone)));
      expect(merged).toEqual(alone);
      expect(identityVerdict(id, merged)).toEqual(identityVerdict(id, alone));
    },
  );
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
