import { decodeValue } from "./decode";
import { err, ok, type Result } from "./result";
import type { Block, Mask, Parameter, Stamp, Survey } from "./stored-profile";

// The decode of what a copy reads, under a profile's `meter_clock` and `stored` sections, as
// `contract/fixtures/stored-decode.v1.json` pins it; follows `alavi`'s `Alavi.Decode.Stored`. Words
// are in register-address order, as read from the meter. A stamp is the meter's own local time,
// with no zone, never corrected. A value is decoded as an f32 register is, to a decimal string.
// Changing this changes what may be billed.

export type StoredError = "wrong_word_count" | "zero_interval" | "interval_not_dividing_a_day";

/** One history or snapshot entry: neither an unsupported quantity nor a NaN is an entry. */
export interface BlockEntry {
  readonly meterTime: string;
  readonly entries: readonly { readonly registerKey: string; readonly value: string }[];
  readonly unsupported: readonly string[];
  readonly notFinite: readonly string[];
}

/** One load-survey parameter of one day: each interval ended by the meter's clock, by its start. */
export interface SurveyDay {
  readonly meterTime: string;
  readonly intervalS: number;
  readonly entries: readonly { readonly meterTime: string; readonly value: string }[];
  readonly notFinite: readonly string[];
  /** The intervals the meter's clock had not ended: none for a day past. */
  readonly notEnded: number;
}

const dayMinutes = 1440;
const maskWidths = { u16: 1, u32: 2, u64: 4 } as const satisfies Record<Mask["type"], number>;

const unsigned = (words: readonly number[], order: "high_first" | "low_first"): bigint =>
  (order === "high_first" ? words : words.toReversed()).reduce((n, w) => (n << 16n) | BigInt(w), 0n);

const localTime = (ms: number): string => new Date(ms).toISOString().slice(0, 19);
const epochMs = (epoch: string): number => Date.parse(`${epoch}Z`);

// contract: test/stored-decode.test.ts "decodeStamp"
export const decodeStamp = (
  stamp: Pick<Stamp, "word_order" | "epoch">,
  words: readonly number[],
): Result<string, "wrong_word_count"> =>
  words.length === 2
    ? ok(localTime(epochMs(stamp.epoch) + Number(unsigned(words, stamp.word_order)) * 1000))
    : err("wrong_word_count");

// contract: test/stored-decode.test.ts "decodeMask"
/** The mask's set bits, lowest first: bit n set supports the entry with mask_bit or number n. */
export const decodeMask = (mask: Mask, words: readonly number[]): Result<readonly number[], "wrong_word_count"> => {
  const width = maskWidths[mask.type];
  if (words.length !== width) return err("wrong_word_count");
  const n = unsigned(words, mask.type === "u16" ? "high_first" : mask.word_order);
  return ok([...Array(width * 16).keys()].filter((bit) => ((n >> BigInt(bit)) & 1n) === 1n));
};

// contract: test/stored-decode.test.ts "decodeMask"
/** The profile's load-survey parameters a mask's bits support: the ones a copy reads. */
export const supportedParameters = (
  survey: Pick<Survey, "parameters">,
  bits: readonly number[],
): readonly Parameter[] => survey.parameters.filter((p) => bits.includes(p.number));

// A NaN or an infinity is no value.
const f32 = (order: "high_first" | "low_first", words: readonly number[]) =>
  decodeValue({ type: "f32", word_order: order }, words);

// contract: test/stored-decode.test.ts "decodeBlock"
/** `mask` is the block's mask words, null when the profile has none. */
export const decodeBlock = (
  block: Pick<Block, "stamp" | "mask" | "registers">,
  read: {
    readonly stamp: readonly number[];
    readonly mask: readonly number[] | null;
    readonly registers: Readonly<Record<string, readonly number[]>>;
  },
): Result<BlockEntry, StoredError> => {
  const at = decodeStamp(block.stamp, read.stamp);
  if (!at.ok) return at;
  const bits = blockBits(block.mask, read.mask);
  if (!bits.ok) return bits;
  const decoded = block.registers.map((r) =>
    bits.value === null || (r.mask_bit !== undefined && bits.value.includes(r.mask_bit))
      ? { key: r.key, value: f32(r.word_order, read.registers[r.key] ?? []) }
      : { key: r.key, value: null },
  );
  if (decoded.some((d) => d.value !== null && !d.value.ok && d.value.error === "wrong_word_count"))
    return err("wrong_word_count");
  return ok({
    meterTime: at.value,
    entries: decoded.flatMap((d) => (d.value?.ok ? [{ registerKey: d.key, value: d.value.value }] : [])),
    unsupported: decoded.flatMap((d) => (d.value === null ? [d.key] : [])),
    notFinite: decoded.flatMap((d) => (d.value !== null && !d.value.ok ? [d.key] : [])),
  });
};

const blockBits = (
  mask: Mask | undefined,
  words: readonly number[] | null,
): Result<readonly number[] | null, "wrong_word_count"> => {
  if (mask === undefined) return words === null ? ok(null) : err("wrong_word_count");
  return words === null ? err("wrong_word_count") : decodeMask(mask, words);
};

// contract: test/stored-decode.test.ts "decodeInterval"
/** The interval register's minutes, which must divide a day. */
export const decodeInterval = (words: readonly number[]): Result<number, StoredError> => {
  const [minutes] = words;
  if (words.length !== 1 || minutes === undefined) return err("wrong_word_count");
  if (minutes === 0) return err("zero_interval");
  return dayMinutes % minutes === 0 ? ok(minutes) : err("interval_not_dividing_a_day");
};

// contract: test/stored-decode.test.ts "decodeDay"
/**
 * One parameter's day. `values` holds every interval of the day, two words each. `clock` is the
 * meter clock's words, read on the day being copied, or null for a day past: an interval is an
 * entry only once its end is no later than the clock.
 */
export const decodeDay = (
  survey: Pick<Survey, "stamp" | "values">,
  read: {
    readonly stamp: readonly number[];
    readonly interval: readonly number[];
    readonly values: readonly number[];
    readonly clock: { readonly stamp: Pick<Stamp, "word_order" | "epoch">; readonly words: readonly number[] } | null;
  },
): Result<SurveyDay, StoredError> => {
  const at = decodeStamp(survey.stamp, read.stamp);
  if (!at.ok) return at;
  const minutes = decodeInterval(read.interval);
  if (!minutes.ok) return minutes;
  if (read.values.length !== 2 * (dayMinutes / minutes.value)) return err("wrong_word_count");
  const clock = read.clock === null ? ok(null) : decodeStamp(read.clock.stamp, read.clock.words);
  if (!clock.ok) return clock;
  return ok(intervals(at.value, minutes.value * 60, survey.values.word_order, read.values, clock.value));
};

const intervals = (
  day: string,
  step: number,
  order: "high_first" | "low_first",
  words: readonly number[],
  clock: string | null,
): SurveyDay => {
  const start = epochMs(day);
  const timed = Array.from({ length: words.length / 2 }, (_, i) => ({
    startMs: start + i * step * 1000,
    value: f32(order, words.slice(2 * i, 2 * i + 2)),
  }));
  const ended = timed.filter((t) => clock === null || t.startMs + step * 1000 <= epochMs(clock));
  return {
    meterTime: day,
    intervalS: step,
    entries: ended.flatMap((t) => (t.value.ok ? [{ meterTime: localTime(t.startMs), value: t.value.value }] : [])),
    notFinite: ended.flatMap((t) => (t.value.ok ? [] : [localTime(t.startMs)])),
    notEnded: timed.length - ended.length,
  };
};
