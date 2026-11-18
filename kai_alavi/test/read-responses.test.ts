import { describe, expect, test } from "bun:test";
import { type Expected, type Framing, parseResponse, type Skipped, takeReply } from "../src/index";
import { loadResponseFixture } from "./contract";

const fixture = loadResponseFixture();
const hex = (b: Uint8Array): string => Buffer.from(b).toString("hex");

type Outcome = { skipped: Skipped[]; result: unknown; rest: string };

/** Step the buffer as the app's socket loop would, with no more bytes arriving. */
const run = (
  framing: Framing,
  buffer: Uint8Array,
  expected: Expected,
  count: number,
  skipped: Skipped[] = [],
): Outcome => {
  const step = takeReply(framing, buffer, expected);
  switch (step.kind) {
    case "skip":
      return run(framing, step.rest, expected, count, [...skipped, step.why]);
    case "incomplete":
      return { skipped, result: "incomplete", rest: hex(buffer) };
    case "error":
      return { skipped, result: { error: step.error }, rest: hex(step.rest ?? buffer) };
    case "reply": {
      const parsed = parseResponse(expected.table, count, step.pdu);
      const result = parsed.ok
        ? { words: parsed.value }
        : parsed.error.kind === "exception"
          ? { exception: parsed.error.code }
          : { error: parsed.error.kind };
      return { skipped, result, rest: hex(step.rest) };
    }
    default: {
      const unknown: never = step;
      return unknown;
    }
  }
};

/** A small seeded generator, so a failure names inputs that reproduce. */
const bytes = (seed: number, length: number): Uint8Array =>
  Uint8Array.from({ length }, (_, i) => Math.floor(Math.abs(Math.sin(seed * 9973 + i * 7919)) * 256) % 256);

/** Step until something other than a skip, checking that every skip shrinks the buffer. */
const drain = (framing: Framing, buffer: Uint8Array, expected: Expected): string => {
  const step = takeReply(framing, buffer, expected);
  if (step.kind !== "skip") return step.kind;
  expect(step.rest.length).toBeLessThan(buffer.length);
  return drain(framing, step.rest, expected);
};

describe("takeReply", () => {
  test.each(fixture.cases.map((c) => [`${c.framing}: ${c.why}`, c] as const))("%s", (_, c) => {
    const e = c.expected;
    const expected = { transactionId: e.transaction_id, unitId: e.unit_id, table: e.table };
    const outcome = run(c.framing, Uint8Array.from(Buffer.from(c.buffer, "hex")), expected, e.count);
    expect(outcome).toEqual({ skipped: c.skipped, result: c.result, rest: c.rest });
  });

  test("any bytes step to a reply, an error or incomplete, never a throw, and every skip shrinks the buffer", () => {
    const framings: readonly Framing[] = ["tcp", "rtu_over_tcp"];
    const expected: Expected = { transactionId: 1, unitId: 1, table: "holding" };
    for (let seed = 0; seed < 2000; seed++) {
      // Byte 0 is often our unit and byte 1 our function code, so the deep paths are reached.
      const raw = bytes(seed, seed % 40);
      const buffer = seed % 2 === 0 && raw.length > 1 ? Uint8Array.from([1, seed % 3 === 0 ? 0x83 : 3, ...raw]) : raw;
      for (const framing of framings) {
        expect(drain(framing, buffer, expected)).not.toBe("skip");
        expect(() => parseResponse("holding", seed % 126, buffer)).not.toThrow();
      }
    }
  });
});

describe("parseResponse", () => {
  test("a count no read could have is a malformed response, not a throw", () => {
    for (const count of [-1, 0, 0.5, 126, Number.NaN])
      expect(parseResponse("holding", count, new Uint8Array())).toEqual({
        ok: false,
        error: { kind: "malformed_response" },
      });
  });
});
