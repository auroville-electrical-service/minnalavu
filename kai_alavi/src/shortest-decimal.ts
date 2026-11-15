import { err, ok, type Result } from "./result";

// The shortest decimal that names a float's bits: the fewest significant digits that parse back,
// at the float's own width and rounding half to even, to the same bits, and of those the nearest
// the exact value, a tie going to the even last digit. Found in exact integer arithmetic, so an
// f32 is never widened to f64 first, and no engine's number formatting is relied on.

export interface FloatFormat {
  readonly mantissaBits: bigint;
  readonly exponentBits: bigint;
  /** Enough significant digits to name every value. */
  readonly maxDigits: number;
}

export const f32: FloatFormat = { mantissaBits: 23n, exponentBits: 8n, maxDigits: 9 };
export const f64: FloatFormat = { mantissaBits: 52n, exponentBits: 11n, maxDigits: 17 };

// Written out in full, no exponent, no trailing zeros or point; negative zero is "-0".
export const shortestDecimal = (format: FloatFormat, bits: bigint): Result<string, "not_finite"> => {
  const width = 1n + format.exponentBits + format.mantissaBits;
  const magnitude = bits & ((1n << (width - 1n)) - 1n);
  const sign = bits >> (width - 1n) === 1n ? "-" : "";
  if (magnitude >> format.mantissaBits === (1n << format.exponentBits) - 1n) return err("not_finite");
  return ok(sign + (magnitude === 0n ? "0" : positional(shortest(format, magnitude))));
};

interface Digits {
  readonly k: bigint;
  readonly scale: number;
}

// Every finite value is a whole multiple of the smallest subnormal, so every value and every
// midpoint between neighbours is a whole multiple of half of it. Below, a value or midpoint is
// held as that multiple: an integer over 2^(shift + 1), the smallest subnormal being 2^-shift.
const shift = (format: FloatFormat): bigint => (1n << (format.exponentBits - 1n)) - 2n + format.mantissaBits;

// The value with these bits, in units of the smallest subnormal. One past the largest finite
// value gives 2^(largest exponent + 1), the bound its rounding interval is taken from.
const whole = (format: FloatFormat, bits: bigint): bigint => {
  const exponent = bits >> format.mantissaBits;
  const mantissa = bits & ((1n << format.mantissaBits) - 1n);
  return exponent === 0n ? mantissa : (mantissa | (1n << format.mantissaBits)) << (exponent - 1n);
};

const shortest = (format: FloatFormat, bits: bigint): Digits => {
  const denominator = 1n << (shift(format) + 1n);
  const value = whole(format, bits);
  const x = 2n * value;
  const low = whole(format, bits - 1n) + value;
  const high = value + whole(format, bits + 1n);
  const closed = bits % 2n === 0n;
  const e = exponent10(x, denominator);
  const inside = (k: bigint, scale: number): boolean => {
    const vsLow = compare(k, scale, low, denominator);
    const vsHigh = compare(k, scale, high, denominator);
    return (vsLow > 0 && vsHigh < 0) || (closed && (vsLow === 0 || vsHigh === 0));
  };
  for (let n = 1; n <= format.maxDigits; n++) {
    const scale = e - n + 1;
    const nearest = nearestHalfEven(x, scale, denominator);
    // A neighbour can name the bits only where the interval is lopsided (at a power of two).
    const k = [nearest, nearest - 1n, nearest + 1n].find((c) => inside(c, scale));
    if (k !== undefined) return { k, scale };
  }
  throw new Error(`no ${format.maxDigits}-digit decimal names the float with bits ${bits.toString(16)}`);
};

const pow10 = (n: number): bigint => 10n ** BigInt(n);

// The sign of k * 10^scale - y / denominator.
const compare = (k: bigint, scale: number, y: bigint, denominator: bigint): number => {
  const [a, b] = scale >= 0 ? [k * pow10(scale) * denominator, y] : [k * denominator, y * pow10(-scale)];
  return a > b ? 1 : a < b ? -1 : 0;
};

// x / denominator / 10^scale, rounded half to even.
const nearestHalfEven = (x: bigint, scale: number, denominator: bigint): bigint => {
  const [num, den] = scale >= 0 ? [x, denominator * pow10(scale)] : [x * pow10(-scale), denominator];
  const q = num / den;
  const twice = 2n * (num % den);
  if (twice > den) return q + 1n;
  if (twice < den) return q;
  return q + (q % 2n);
};

// The e with 10^e <= x / denominator < 10^(e + 1), searched near the estimate from bit lengths.
const exponent10 = (x: bigint, denominator: bigint): number => {
  const guess = Math.floor((x.toString(2).length - denominator.toString(2).length) * Math.log10(2));
  const e = [0, -1, 1, -2, 2]
    .map((d) => guess + d)
    .find((c) => compare(1n, c, x, denominator) <= 0 && compare(1n, c + 1, x, denominator) > 0);
  if (e === undefined) throw new Error("no power of ten brackets the value");
  return e;
};

const positional = ({ k, scale }: Digits): string => {
  const digits = k.toString();
  if (scale >= 0) return digits + "0".repeat(scale);
  const padded = digits.padStart(1 - scale, "0");
  const point = padded.length + scale;
  const fraction = padded.slice(point).replace(/0+$/, "");
  return fraction === "" ? padded.slice(0, point) : `${padded.slice(0, point)}.${fraction}`;
};
