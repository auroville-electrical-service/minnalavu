import { crc16 } from "./crc";
import { pduBytes, type ReadRequest } from "./pdu";

export type Framing = "tcp" | "rtu_over_tcp";

// contract: test/read-requests.test.ts "encodeRequest"
// `transactionId` is 0..0xFFFF and `unitId` 0..255; neither is checked here.
export const encodeRequest = (
  framing: Framing,
  transactionId: number,
  unitId: number,
  request: ReadRequest,
): Uint8Array => {
  const pdu = pduBytes(request);
  switch (framing) {
    case "tcp":
      return Uint8Array.from([transactionId >> 8, transactionId & 0xff, 0, 0, 0, pdu.length + 1, unitId, ...pdu]);
    case "rtu_over_tcp": {
      const body = [unitId, ...pdu];
      const crc = crc16(body);
      return Uint8Array.from([...body, crc & 0xff, crc >> 8]);
    }
    default: {
      const unknown: never = framing;
      return unknown;
    }
  }
};
