import { describe, expect, test } from "bun:test";
import {
  batchJson,
  blockEntries,
  dayEntries,
  decodeBlock,
  decodeDay,
  type IdentifiedMeter,
  meterClockRead,
} from "../src/index";
import { loadProfiles, loadStoredFixture } from "./contract";

const fixture = loadStoredFixture();
const profiles = loadProfiles();
const at = new Date("2026-11-16T02:10:00Z");

const sections = (name: string) => {
  const p = profiles.get(name);
  if (!p?.stored || !p.meter_clock) throw new Error(`${name} has no stored sections`);
  return { version: p.version, stored: p.stored, clock: p.meter_clock };
};

const meter = (name: string): IdentifiedMeter => ({
  endpoint: { host: "10.0.0.21", port: 502 },
  unitId: 1,
  serial: "SIM-1",
  profile: name,
  profileVersion: sections(name).version,
  productCode: "ELITE440-445",
});

describe("blockEntries", () => {
  test("one stored entry per decoded quantity, under the entry's stamp and the slot it was read at", () => {
    const c = fixture.blocks[0];
    if (!c?.mask_words) throw new Error("the fixture's first block moved");
    const decoded = decodeBlock(sections(c.profile).stored[c.store], {
      stamp: c.stamp_words,
      mask: c.mask_words,
      registers: c.registers,
    });
    if (!decoded.ok) throw new Error(decoded.error);
    const entries = blockEntries(meter(c.profile), c.store, 3, at, decoded.value);
    expect(entries).toEqual(
      c.entries.map((e) => ({
        meter: meter(c.profile),
        store: "history",
        registerKey: e.register_key,
        meterTime: c.meter_time,
        value: e.value,
        slot: 3,
        copiedAt: at,
      })),
    );
  });
});

describe("dayEntries", () => {
  test("one stored entry per ended interval, at its start, with the interval's length", () => {
    const c = fixture.load_survey.find((s) => s.clock_words !== undefined);
    if (!c?.clock_words) throw new Error("the fixture has no current day");
    const { stored, clock } = sections(c.profile);
    const decoded = decodeDay(stored.load_survey, {
      stamp: c.stamp_words,
      interval: c.interval_words,
      values: c.values_words,
      clock: { stamp: clock, words: c.clock_words },
    });
    if (!decoded.ok) throw new Error(decoded.error);
    const entries = dayEntries(meter(c.profile), c.register_key, 0, at, decoded.value);
    expect(entries).toEqual(
      c.entries.map((e) => ({
        meter: meter(c.profile),
        store: "load_survey",
        registerKey: c.register_key,
        meterTime: e.meter_time,
        intervalS: c.interval_s,
        value: e.value,
        slot: 0,
        copiedAt: at,
      })),
    );
    const json = batchJson({
      id: "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b",
      sentAt: at,
      clock: { source: "unsynced", lastSyncAt: null },
      backlog: {
        events: 1,
        bytes: 1,
        batches: 1,
        oldest: null,
        maxBytes: 1,
        refused: 0,
        discardedFiles: 0,
        quarantined: 0,
      },
      readings: [],
      missedReads: [],
      storedEntries: entries,
    });
    expect(json).toMatchObject({
      stored_entries: entries.map(() => expect.objectContaining({ store: "load_survey", interval_s: c.interval_s })),
    });
  });
});

describe("meterClockRead", () => {
  test("the meter's clock beside the collector's, or no read for the wrong number of words", () => {
    const c = fixture.stamps.find((s) => s.field === "meter_clock" && s.profile === "elite_500");
    if (!c) throw new Error("the fixture has no 500 meter clock");
    const { clock } = sections(c.profile);
    expect(meterClockRead(meter(c.profile), clock, c.raw_words, at)).toEqual({
      ok: true,
      value: { meter: meter(c.profile), meterTime: c.meter_time, at },
    });
    expect(meterClockRead(meter(c.profile), clock, [1], at)).toEqual({ ok: false, error: "wrong_word_count" });
  });
});
