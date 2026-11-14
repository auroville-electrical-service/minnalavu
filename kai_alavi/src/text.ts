// Text a meter reports in registers: ASCII, two bytes per register, high byte first. Shared by
// the identity check and the firmware names; follows `alavi`'s `Alavi.Profile.Text`.

export const bytesOf = (words: readonly number[]): readonly number[] => words.flatMap((w) => [w >> 8, w & 0xff]);

export const printable = (bytes: readonly number[]): string | null =>
  bytes.length > 0 && bytes.every((b) => b >= 0x20 && b <= 0x7e) ? String.fromCharCode(...bytes) : null;

// Trailing NULs, then surrounding ASCII whitespace: the bytes alavi trims.
const space = (b: number): boolean => b === 0x20 || (b >= 0x09 && b <= 0x0d);

export const trimmed = (bytes: readonly number[]): readonly number[] => {
  const end = bytes.findLastIndex((b) => b !== 0) + 1;
  const unpadded = bytes.slice(0, end);
  const first = unpadded.findIndex((b) => !space(b));
  if (first === -1) return [];
  return unpadded.slice(first, unpadded.findLastIndex((b) => !space(b)) + 1);
};
