import { err, ok, type Result } from "./result";

// Only function codes 03 and 04 exist here: there is deliberately no way to build a write request,
// because this system never writes to meters. The opaque type does not hold at runtime, so a built
// request is also frozen and recorded, and `pduBytes` refuses any other.

declare const brand: unique symbol;

export interface ReadRequest {
  readonly bytes: readonly number[];
  readonly [brand]: true;
}

const built = new WeakSet<object>();

/** Register table: `holding` is function code 03, `input` is 04. */
export type Table = "holding" | "input";

const maxCount = 125;
const functionCodes = { holding: 3, input: 4 } as const satisfies Record<Table, number>;

const isTable = (table: string): table is Table => table === "holding" || table === "input";

// contract: test/read-only.test.ts "readRequest"
// `address` is zero-based.
export const readRequest = (table: string, address: number, count: number): Result<ReadRequest, "invalid_request"> => {
  const valid =
    isTable(table) &&
    Number.isInteger(address) &&
    Number.isInteger(count) &&
    address >= 0 &&
    count >= 1 &&
    count <= maxCount &&
    address + count <= 0x10000;
  if (!valid) return err("invalid_request");
  const bytes = Object.freeze([functionCodes[table], address >> 8, address & 0xff, count >> 8, count & 0xff]);
  const request = Object.freeze({ bytes }) as ReadRequest;
  built.add(request);
  return ok(request);
};

// contract: test/read-only.test.ts "pduBytes"
// Throws on any request `readRequest` did not build.
export const pduBytes = (request: ReadRequest): readonly number[] => {
  const [fc, aHi = 0, aLo = 0, cHi = 0, cLo = 0] = request.bytes;
  const count = (cHi << 8) | cLo;
  const read =
    built.has(request) &&
    Object.isFrozen(request) &&
    request.bytes.length === 5 &&
    (fc === 3 || fc === 4) &&
    count >= 1 &&
    count <= maxCount &&
    ((aHi << 8) | aLo) + count <= 0x10000;
  if (!read) throw new Error("refused: not a read request built by readRequest");
  return request.bytes;
};

export const functionCode = (table: Table): 3 | 4 => functionCodes[table];
