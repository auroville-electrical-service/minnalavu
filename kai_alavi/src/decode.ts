import Big from "big.js";
import type { DataType, Register } from "./profile";
import { err, ok, type Result } from "./result";

export type DecodeError = "wrong_word_count" | "not_finite";

const wordCounts = { u16: 1, i16: 1, u32: 2, i32: 2, f32: 2, u64: 4, f64: 4 } as const satisfies Record<
  DataType,
  number
>;

export const wordCount = (type: DataType): 1 | 2 | 4 => wordCounts[type];

// contract: test/decode.test.ts "decodeValue"
// `words` are as read from the meter, in register-address order. Changing this changes what is billed.
export const decodeValue = (
  register: Pick<Register, "type" | "word_order" | "decimals">,
  words: readonly number[],
): Result<string, DecodeError> => {
  if (words.length !== wordCount(register.type)) return err("wrong_word_count");
  const ordered = register.word_order === "high_first" ? words : words.toReversed();
  const view = new DataView(new ArrayBuffer(ordered.length * 2));
  ordered.forEach((word, i) => {
    view.setUint16(i * 2, word);
  });
  return number(view, register.type, register.decimals);
};

const number = (view: DataView, type: DataType, decimals: number): Result<string, DecodeError> => {
  switch (type) {
    case "u16":
      return ok(scaled(BigInt(view.getUint16(0)), decimals));
    case "i16":
      return ok(scaled(BigInt(view.getInt16(0)), decimals));
    case "u32":
      return ok(scaled(BigInt(view.getUint32(0)), decimals));
    case "i32":
      return ok(scaled(BigInt(view.getInt32(0)), decimals));
    case "u64":
      return ok(scaled(view.getBigUint64(0), decimals));
    case "f32":
      return rounded(view.getFloat32(0), decimals);
    case "f64":
      return rounded(view.getFloat64(0), decimals);
    default: {
      const unknown: never = type;
      return unknown;
    }
  }
};

const scaled = (n: bigint, decimals: number): string => {
  const sign = n < 0n ? "-" : "";
  const digits = (n < 0n ? -n : n).toString().padStart(decimals + 1, "0");
  const point = digits.length - decimals;
  return decimals === 0 ? sign + digits : `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
};

const rounded = (f: number, decimals: number): Result<string, DecodeError> => {
  if (!Number.isFinite(f)) return err("not_finite");
  // Number#toString and Big#toFixed drop the sign of a zero, which alavi's Decimal keeps.
  const shortest = Object.is(f, -0) ? "-0" : f.toString();
  const value = new Big(shortest).round(decimals, Big.roundHalfEven);
  const text = value.toFixed(decimals);
  return ok(value.s === -1 && !text.startsWith("-") ? `-${text}` : text);
};
