const bits = [0, 1, 2, 3, 4, 5, 6, 7] as const;
const shift = (c: number): number => (c & 1 ? (c >>> 1) ^ 0xa001 : c >>> 1);

// contract: test/read-requests.test.ts "crc16"
export const crc16 = (bytes: readonly number[]): number =>
  bytes.reduce((crc, byte) => bits.reduce(shift, crc ^ byte), 0xffff);
