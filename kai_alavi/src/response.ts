import { crc16 } from "./crc";
import type { Framing } from "./framing";
import { functionCode, type Table } from "./pdu";
import { err, ok, type Result } from "./result";

/** What a reply must answer. `transactionId` is unused for `rtu_over_tcp`. */
export interface Expected {
  readonly transactionId: number;
  readonly unitId: number;
  readonly table: Table;
}

/**
 * - `stale` (TCP): a whole frame with another transaction id, such as the late answer to a request
 *   that timed out.
 * - `noise` (RTU): a byte that cannot start the reply, such as a stray byte at bus turnaround.
 * - `bad_crc` (RTU): one byte of what began like the reply but failed its CRC; only one byte goes,
 *   so a real frame behind it is still found.
 */
export type Skipped = "stale" | "noise" | "bad_crc";
export type FrameError = "malformed_frame" | "unexpected_response";

/** `error` with `rest`: the frame was not the reply but was taken whole, so the connection is still in step. */
export type Step =
  | { readonly kind: "reply"; readonly pdu: Uint8Array; readonly rest: Uint8Array }
  | { readonly kind: "skip"; readonly why: Skipped; readonly rest: Uint8Array }
  | { readonly kind: "incomplete" }
  | { readonly kind: "error"; readonly error: FrameError; readonly rest?: Uint8Array };

const incomplete: Step = { kind: "incomplete" };
const view = (b: Uint8Array): DataView => new DataView(b.buffer, b.byteOffset, b.byteLength);

// contract: test/read-responses.test.ts "takeReply"
// The caller owns the socket: call again on `rest` after a skip, or with more bytes after `incomplete`.
export const takeReply = (framing: Framing, buffer: Uint8Array, expected: Expected): Step => {
  switch (framing) {
    case "tcp":
      return tcpReply(buffer, expected);
    case "rtu_over_tcp":
      return rtuReply(buffer, expected);
    default: {
      const unknown: never = framing;
      return unknown;
    }
  }
};

const mbap = 7;

const tcpReply = (buffer: Uint8Array, expected: Expected): Step => {
  if (buffer.length < mbap) return incomplete;
  const header = view(buffer);
  const length = header.getUint16(4);
  if (header.getUint16(2) !== 0 || length < 2 || length > 254) return { kind: "error", error: "malformed_frame" };
  const end = mbap - 1 + length;
  if (buffer.length < end) return incomplete;
  const rest = buffer.subarray(end);
  if (header.getUint16(0) !== expected.transactionId) return { kind: "skip", why: "stale", rest };
  if (header.getUint8(6) !== expected.unitId) {
    // A gateway's lone 0B under a byte of its own, not the unit asked: taken whole, so the
    // connection stays in step and `rest` is what follows it.
    const gatewayFault = length === 2 && header.getUint8(mbap) === 0x0b;
    return gatewayFault
      ? { kind: "error", error: "unexpected_response", rest }
      : { kind: "error", error: "unexpected_response" };
  }
  return { kind: "reply", pdu: buffer.subarray(mbap, end), rest };
};

const rtuReply = (buffer: Uint8Array, expected: Expected): Step => {
  if (buffer.length === 0) return incomplete;
  const noise: Step = { kind: "skip", why: "noise", rest: buffer.subarray(1) };
  if (buffer[0] !== expected.unitId) return noise;
  if (buffer.length === 1) return incomplete;
  const fc = functionCode(expected.table);
  const head = view(buffer);
  const code = head.getUint8(1);
  if (code !== fc && code !== fc + 0x80) return noise;
  if (code === fc && buffer.length < 3) return incomplete;
  const body = code === fc ? 3 + head.getUint8(2) : 3;
  if (buffer.length < body + 2) return incomplete;
  if (crc16([...buffer.subarray(0, body)]) !== head.getUint16(body, true)) {
    return { kind: "skip", why: "bad_crc", rest: buffer.subarray(1) };
  }
  return { kind: "reply", pdu: buffer.subarray(1, body), rest: buffer.subarray(body + 2) };
};

export type ResponseError =
  | { readonly kind: "exception"; readonly code: number }
  | { readonly kind: "malformed_response" };

// contract: test/read-responses.test.ts "parseResponse"
export const parseResponse = (
  table: Table,
  count: number,
  pdu: Uint8Array,
): Result<readonly number[], ResponseError> => {
  if (!Number.isInteger(count) || count < 1 || count > 125) return err({ kind: "malformed_response" });
  const fc = functionCode(table);
  const bytes = view(pdu);
  if (pdu.length === 2 && bytes.getUint8(0) === fc + 0x80 && bytes.getUint8(1) > 0) {
    return err({ kind: "exception", code: bytes.getUint8(1) });
  }
  const size = 2 * count;
  if (pdu.length !== 2 + size || bytes.getUint8(0) !== fc || bytes.getUint8(1) !== size) {
    return err({ kind: "malformed_response" });
  }
  return ok(Array.from({ length: count }, (_, i) => bytes.getUint16(2 + 2 * i)));
};
