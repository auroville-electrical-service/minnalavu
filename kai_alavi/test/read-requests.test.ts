import { describe, expect, test } from "bun:test";
import { crc16, encodeRequest, readRequest } from "../src/index";
import { loadRequestFixture } from "./contract";

const fixture = loadRequestFixture();
const hex = (bytes: Uint8Array): string => Buffer.from(bytes).toString("hex");

describe("encodeRequest", () => {
  test.each(fixture.requests.map((c) => [`${c.framing} ${c.table} ${c.address}+${c.count}`, c] as const))(
    "%s",
    (_, c) => {
      const request = readRequest(c.table, c.address, c.count);
      if (!request.ok) throw new Error(`refused ${JSON.stringify(c)}`);
      expect(hex(encodeRequest(c.framing, c.transaction_id, c.unit_id, request.value))).toBe(c.frame);
    },
  );
});

describe("crc16", () => {
  test("CRC-16/MODBUS check value", () => {
    expect(crc16([..."123456789"].map((ch) => ch.charCodeAt(0)))).toBe(0x4b37);
  });
});
