import type { FloatType, IntegerType, WordOrder } from "./profile";
import { err, ok, type Result } from "./result";
import { f32, f64, shortestDecimal } from "./shortest-decimal";

export type DecodeError = "wrong_word_count" | "not_finite";

/** How a register's words become its value: what `decodeValue` reads of a profile entry. */
export type Decoding =
  | { readonly type: IntegerType; readonly word_order: WordOrder; readonly decimals: number }
  | { readonly type: FloatType; readonly word_order: WordOrder };

const wordCounts = { u16: 1, i16: 1, u32: 2, i32: 2, f32: 2, u64: 4, f64: 4 } as const satisfies Record<
  Decoding["type"],
  number
>;

export const wordCount = (type: Decoding["type"]): 1 | 2 | 4 => wordCounts[type];

// contract: test/decode.test.ts "decodeValue"
// `words` are as read from the meter, in register-address order. An integer's value is exact, with
// `decimals` places; a float's is the shortest decimal that names its bits at its own width, so
// lossless but not its exact value. Changing this changes what is billed.
export const decodeValue = (register: Decoding, words: readonly number[]): Result<string, DecodeError> => {
  if (words.length !== wordCount(register.type)) return err("wrong_word_count");
  const ordered = register.word_order === "high_first" ? words : words.toReversed();
  const view = new DataView(new ArrayBuffer(ordered.length * 2));
  ordered.forEach((word, i) => {
    view.setUint16(i * 2, word);
  });
  return number(view, register);
};

const number = (view: DataView, register: Decoding): Result<string, DecodeError> => {
  switch (register.type) {
    case "u16":
      return ok(scaled(BigInt(view.getUint16(0)), register.decimals));
    case "i16":
      return ok(scaled(BigInt(view.getInt16(0)), register.decimals));
    case "u32":
      return ok(scaled(BigInt(view.getUint32(0)), register.decimals));
    case "i32":
      return ok(scaled(BigInt(view.getInt32(0)), register.decimals));
    case "u64":
      return ok(scaled(view.getBigUint64(0), register.decimals));
    case "f32":
      return shortestDecimal(f32, BigInt(view.getUint32(0)));
    case "f64":
      return shortestDecimal(f64, view.getBigUint64(0));
    default: {
      const unknown: never = register;
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
