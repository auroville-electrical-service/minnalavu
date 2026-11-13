import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import Ajv2020 from "ajv/dist/2020";
import addFormats from "ajv-formats";
import {
  type Batch,
  batchJson,
  findRegister,
  type IdentifiedMeter,
  type Meter,
  type MissedRead,
  type MissReason,
  readRegister,
} from "../src/index";
import { contract, loadProfiles } from "./contract";

const read = (path: string): unknown => JSON.parse(readFileSync(join(contract, path), "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const schema = read("schema/batch.v1.schema.json");
if (typeof schema !== "object" || schema === null) throw new Error("the batch schema is not an object");
const validate = ajv.compile(schema);

const profiles = loadProfiles();
const register = (profile: string, key: string) => {
  const found = findRegister(profiles.get(profile) ?? { registers: [] }, key);
  if (!found.ok) throw new Error(`no ${key} in ${profile}`);
  return found.value;
};

const at = (s: string) => new Date(`2026-11-01T00:00:0${s}Z`);
const meter = (host: string, unitId: number, serial: string | null, profile: string): Meter => ({
  endpoint: { host, port: 502 },
  unitId,
  serial,
  profile,
});

const identified = (unitId: number, serial: string, profile: string, productCode: string): IdentifiedMeter => ({
  ...meter("10.0.0.21", unitId, serial, profile),
  serial,
  productCode,
});

const reading = (m: IdentifiedMeter, key: string, words: number[], second: string) => {
  const r = readRegister(m, register(m.profile, key), words, at(second), 1);
  if (!r.ok) throw new Error(`did not decode: ${JSON.stringify(r.error.reason)}`);
  return r.value;
};

const exceptionMiss: MissedRead = {
  meter: meter("10.0.0.21", 9, "SIM-445-0009", "elite_440"),
  registerKey: "active_energy_import",
  at: at("2"),
  reason: { kind: "exception", code: 11 },
  attempts: 3,
};

/** The events of `contract/fixtures/batch.v1.basic.json`, as kai_alavi holds them. */
const basic: Batch = {
  id: "0b6f8d2e-5c1a-4e7b-9a3d-2f4c6e8a0b1c",
  sentAt: new Date("2026-11-01T00:05:00Z"),
  clock: { source: "ntp", lastSyncAt: new Date("2026-11-01T00:00:12Z") },
  backlog: {
    events: 4,
    bytes: 412,
    batches: 1,
    oldest: at("0"),
    maxBytes: 2_000_000_000,
    refused: 0,
    discardedFiles: 0,
    quarantined: 0,
  },
  readings: [
    reading(identified(1, "SIM-445-0001", "elite_440", "ELITE440-445"), "active_energy_import", [20480, 17562], "0"),
    reading(
      identified(3, "SIM-500-0001", "elite_500", "E500C-5102"),
      "active_energy_export",
      [0, 0, 18944, 16531],
      "1",
    ),
  ],
  missedReads: [
    exceptionMiss,
    {
      meter: meter("10.0.0.22", 1, "SIM-445-0010", "elite_440"),
      registerKey: "active_energy_import",
      at: at("3"),
      reason: { kind: "unreachable", detail: "econnrefused" },
      attempts: 0,
    },
  ],
};

describe("batchJson", () => {
  test("gives contract/fixtures/batch.v1.basic.json from its events", () => {
    expect<unknown>(batchJson(basic)).toEqual(read("fixtures/batch.v1.basic.json"));
  });

  const reasons: readonly MissReason[] = [
    { kind: "exception", code: 2 },
    ...(
      [
        "timeout",
        "closed",
        "invalid_request",
        "unexpected_response",
        "malformed_response",
        "bad_crc",
        "malformed_frame",
      ] as const
    ).map((kind) => ({ kind })),
    { kind: "socket", detail: "x".repeat(500) },
    { kind: "unreachable", detail: "ehostunreach" },
    { kind: "profile_mismatch", detail: 'product code "ELITE500", expected one of ELITE440-445' },
    { kind: "decode", error: "not_finite", rawWords: [0, 0x7fc0] },
  ];

  test("every miss reason makes a batch the schema accepts", () => {
    const missedReads = reasons.map((reason) => ({ ...exceptionMiss, reason }));
    const batch = batchJson({ ...basic, missedReads, clock: { source: "unsynced", lastSyncAt: null } });
    expect(validate(batch) ? [] : validate.errors).toEqual([]);
    expect(batch.missed_reads.map((m) => m.reason)).toEqual(reasons.map((r) => r.kind));
  });

  test("a missed read with no serial read carries null, and never a product code", () => {
    const missed: MissedRead = { ...exceptionMiss, meter: meter("10.0.0.21", 9, null, "elite_440") };
    const batch = batchJson({ ...basic, missedReads: [missed] });
    expect(validate(batch) ? [] : validate.errors).toEqual([]);
    expect(batch.missed_reads[0]?.meter_serial).toBeNull();
    expect(batch.missed_reads[0]).not.toHaveProperty("product_code");
  });

  test("a missed read from an identified meter leaves its product code behind", () => {
    const m = identified(1, "SIM-445-0001", "elite_440", "ELITE440-445");
    const r = readRegister(m, register("elite_440", "active_energy_import"), [0, 0x7fc0], at("4"), 1);
    if (r.ok) throw new Error("decoded words that must not decode");
    const batch = batchJson({ ...basic, missedReads: [r.error] });
    expect(validate(batch) ? [] : validate.errors).toEqual([]);
    expect(batch.missed_reads[0]).toMatchObject({ meter_serial: "SIM-445-0001" });
    expect(batch.missed_reads[0]).not.toHaveProperty("product_code");
  });

  test("a socket detail is cut to the schema's 200 characters", () => {
    const missed = { ...exceptionMiss, reason: { kind: "socket", detail: "x".repeat(500) } } satisfies MissedRead;
    expect(batchJson({ ...basic, missedReads: [missed] }).missed_reads[0]?.detail).toHaveLength(200);
  });

  test("a reading the schema accepts keeps its decimal string, not a number", () => {
    const batch = batchJson(basic);
    expect(validate(batch) ? [] : validate.errors).toEqual([]);
    expect(batch.readings.map((r) => r.value)).toEqual(["1234.500", "1234.500"]);
  });

  test("a detail is cut by code points, never inside a surrogate pair", () => {
    const detail = `${"a".repeat(199)}😀😀`;
    const missed: MissedRead = { ...exceptionMiss, reason: { kind: "socket", detail } };
    const cut = batchJson({ ...basic, missedReads: [missed] }).missed_reads[0]?.detail ?? "";
    expect(Array.from(cut)).toHaveLength(200);
    expect(cut.endsWith("😀")).toBe(true);
    expect(cut.isWellFormed()).toBe(true);
  });
});

describe("readRegister", () => {
  const m = identified(1, "SIM-445-0001", "elite_440", "ELITE440-445");

  test("words that do not decode are a missed read that keeps them", () => {
    const r = readRegister(m, register("elite_440", "active_energy_import"), [0, 0x7fc0], at("4"), 2);
    expect(r).toEqual({
      ok: false,
      error: {
        meter: m,
        registerKey: "active_energy_import",
        at: at("4"),
        reason: { kind: "decode", error: "not_finite", rawWords: [0, 0x7fc0] },
        attempts: 2,
      },
    });
    if (r.ok) return;
    expect(batchJson({ ...basic, missedReads: [r.error] }).missed_reads[0]).toMatchObject({
      reason: "decode",
      detail: "not_finite",
      raw_words: [0, 0x7fc0],
      attempts: 2,
    });
  });
});
