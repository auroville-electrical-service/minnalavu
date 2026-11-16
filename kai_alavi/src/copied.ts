import type { IdentifiedMeter, MeterClockRead, StoredEntry } from "./batch";
import { err, ok, type Result } from "./result";
import { type BlockEntry, decodeStamp, type SurveyDay } from "./stored-decode";
import type { Stamp } from "./stored-profile";

// What a copy sends, from what `stored-decode` decoded. The meter's `profileVersion` must be the
// version whose sections decoded it: the store reads each value's unit and kind from that version.

// contract: test/copied.test.ts "blockEntries"
/** `slot` is the selector value the entry was read at. */
export const blockEntries = (
  meter: IdentifiedMeter,
  store: "history" | "snapshot",
  slot: number,
  copiedAt: Date,
  block: Pick<BlockEntry, "meterTime" | "entries">,
): readonly StoredEntry[] =>
  block.entries.map((e) => ({
    meter,
    store,
    registerKey: e.registerKey,
    meterTime: block.meterTime,
    value: e.value,
    slot,
    copiedAt,
  }));

// contract: test/copied.test.ts "dayEntries"
/** `registerKey` is the parameter's; `slot` the day selector's value. */
export const dayEntries = (
  meter: IdentifiedMeter,
  registerKey: string,
  slot: number,
  copiedAt: Date,
  day: Pick<SurveyDay, "intervalS" | "entries">,
): readonly StoredEntry[] =>
  day.entries.map((e) => ({
    meter,
    store: "load_survey",
    registerKey,
    meterTime: e.meterTime,
    intervalS: day.intervalS,
    value: e.value,
    slot,
    copiedAt,
  }));

// contract: test/copied.test.ts "meterClockRead"
/** `stamp` is the profile version's `meter_clock`; `at` the collector's clock when the reply arrived. */
export const meterClockRead = (
  meter: IdentifiedMeter,
  stamp: Pick<Stamp, "word_order" | "epoch">,
  words: readonly number[],
  at: Date,
): Result<MeterClockRead, "wrong_word_count"> => {
  const meterTime = decodeStamp(stamp, words);
  return meterTime.ok ? ok({ meter, meterTime: meterTime.value, at }) : err(meterTime.error);
};
