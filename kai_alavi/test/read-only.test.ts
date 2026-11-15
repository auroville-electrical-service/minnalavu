import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { encodeRequest, type Framing, type ReadRequest, readRequest } from "../src/index";
import { loadRequestFixture } from "./contract";

// The package never writes to a meter; these tests guard that against a later change.

const tables = ["holding", "input", "coil", "discrete_input", "write", ""];
const edges = (top: number): number[] => [-2, -1, 0, 1, 2, 0.5, top - 2, top - 1, top, top + 1, top + 2, Number.NaN];
const addresses = [...edges(0xffff), 0xff83, 0xff82];
const counts = [...Array(130).keys(), -1, -2, 1.5, Number.NaN];
const framings: readonly Framing[] = ["tcp", "rtu_over_tcp"];

const assertRead = (frame: Uint8Array, framing: Framing): void => {
  const pdu = framing === "tcp" ? frame.slice(7) : frame.slice(1, -2);
  const [fc, aHi = 0, aLo = 0, cHi = 0, cLo = 0] = pdu;
  const address = (aHi << 8) | aLo;
  const count = (cHi << 8) | cLo;
  expect(pdu.length).toBe(5);
  expect([3, 4]).toContain(fc ?? -1);
  expect(count).toBeGreaterThanOrEqual(1);
  expect(count).toBeLessThanOrEqual(125);
  expect(address + count).toBeLessThanOrEqual(0x10000);
  expect(frame.length).toBe(framing === "tcp" ? 12 : 8);
};

describe("readRequest", () => {
  test("from every edge input, a request is function code 03 or 04, of a read's exact shape", () => {
    const built = tables.flatMap((table) =>
      addresses.flatMap((address) =>
        counts.flatMap((count) => {
          const r = readRequest(table, address, count);
          return r.ok ? [r.value] : [];
        }),
      ),
    );
    expect(built.length).toBeGreaterThan(0);
    for (const request of built) for (const f of framings) assertRead(encodeRequest(f, 0xffff, 247, request), f);
  });

  test.each(loadRequestFixture().no_request.map((c) => [c.why, c] as const))("no request: %s", (_, c) => {
    expect(readRequest(c.table, c.address, c.count)).toEqual({ ok: false, error: "invalid_request" });
  });

  test("a refused input is refused for every table name that is not holding or input", () => {
    const writable = tables.filter((t) => t !== "holding" && t !== "input");
    expect(writable.every((t) => !readRequest(t, 0, 1).ok)).toBe(true);
  });
});

describe("pduBytes", () => {
  const built = () => {
    const r = readRequest("holding", 0, 1);
    if (!r.ok) throw new Error("refused a valid read");
    return r.value;
  };
  const write = [6, 0, 1, 0, 1];

  test("a built request cannot be changed", () => {
    const request = built();
    expect(() => Object.assign(request, { bytes: write })).toThrow();
    expect(() => (request.bytes as number[]).splice(0, 1, 6)).toThrow();
    expect(encodeRequest("tcp", 0, 1, request)).toEqual(Uint8Array.from([0, 0, 0, 0, 0, 6, 1, 3, 0, 0, 0, 1]));
  });

  test("an object readRequest did not build is refused by both framings, even with read bytes", () => {
    const forged = [
      { bytes: write },
      { bytes: [3, 0, 0, 0, 1] },
      Object.freeze({ bytes: Object.freeze([3, 0, 0, 0, 1]) }),
    ];
    for (const request of forged)
      for (const f of framings) expect(() => encodeRequest(f, 0, 1, request as unknown as ReadRequest)).toThrow();
  });
});

const src = join(import.meta.dir, "..", "src");
const sources = readdirSync(src).map((f) => [f, readFileSync(join(src, f), "utf8")] as const);

describe("only the builder makes a request, and nothing does I/O", () => {
  test("a ReadRequest is constructed only in pdu.ts", () => {
    const makers = sources.filter(([, text]) => /as\s+ReadRequest\b/.test(text)).map(([f]) => f);
    expect(makers).toEqual(["pdu.ts"]);
  });

  test("the package imports nothing but its own modules and zod, and only statically", () => {
    // Bun's own parser lists what the code imports, which comments and strings cannot hide.
    const transpiler = new Bun.Transpiler({ loader: "ts" });
    const imports = sources.flatMap(([f, text]) => transpiler.scanImports(text).map((i) => [f, i.path] as const));
    const foreign = imports.filter(([, spec]) => !spec?.startsWith("./") && spec !== "zod");
    expect(foreign).toEqual([]);
    const dynamic = sources.filter(([, text]) => /\bimport\s*\(|\brequire\b/.test(text)).map(([f]) => f);
    expect(dynamic).toEqual([]);
  });

  test("no source names an I/O API", () => {
    const io = /\b(fetch|WebSocket|XMLHttpRequest|Bun|Deno|process|require|navigator|globalThis)\b|node:/;
    const offenders = sources.filter(([, text]) => io.test(text)).map(([f]) => f);
    expect(offenders).toEqual([]);
  });
});
