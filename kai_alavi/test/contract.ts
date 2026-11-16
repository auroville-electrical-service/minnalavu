import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { type Profile, parseProfile } from "../src/index";

/** The shared contract, read as the collectors read it. */
export const contract = join(import.meta.dir, "..", "..", "contract");

const json = (path: string): unknown => JSON.parse(readFileSync(join(contract, path), "utf8"));

export const loadProfiles = (): ReadonlyMap<string, Profile> =>
  new Map(
    readdirSync(join(contract, "profiles"))
      .filter((f) => f.endsWith(".json"))
      .map((f) => {
        const parsed = parseProfile(json(join("profiles", f)));
        if (!parsed.ok) throw new Error(`${f}: ${parsed.error}`);
        return [parsed.value.profile, parsed.value] as const;
      }),
  );

const words = z.array(z.int().min(0).max(0xffff));

const wordOrder = z.enum(["high_first", "low_first"]);

const decodeFixture = z.object({
  format: z.literal("register-decode/1"),
  profiles: z.array(
    z.object({
      profile: z.string(),
      profile_version: z.int(),
      register_key: z.string(),
      raw_words: words,
      value: z.string(),
      why: z.string(),
    }),
  ),
  types: z.array(
    z.discriminatedUnion("type", [
      z.strictObject({
        type: z.enum(["u16", "i16", "u32", "i32", "u64"]),
        word_order: wordOrder,
        decimals: z.int(),
        raw_words: words,
        value: z.string(),
        why: z.string(),
      }),
      z.strictObject({
        type: z.enum(["f32", "f64"]),
        word_order: wordOrder,
        raw_words: words,
        value: z.string(),
        why: z.string(),
      }),
    ]),
  ),
  no_value: z.array(
    z.object({
      profile: z.string(),
      profile_version: z.int(),
      register_key: z.string(),
      raw_words: words,
      error: z.enum(["wrong_word_count", "not_finite"]),
      why: z.string(),
    }),
  ),
});

const requestFixture = z.object({
  format: z.literal("modbus-read-requests/1"),
  requests: z.array(
    z.object({
      framing: z.enum(["tcp", "rtu_over_tcp"]),
      transaction_id: z.int(),
      unit_id: z.int(),
      table: z.string(),
      address: z.int(),
      count: z.int(),
      frame: z.string(),
    }),
  ),
  no_request: z.array(z.object({ table: z.string(), address: z.int(), count: z.int(), why: z.string() })),
});

const responseFixture = z.object({
  format: z.literal("modbus-read-responses/1"),
  cases: z.array(
    z.object({
      why: z.string(),
      framing: z.enum(["tcp", "rtu_over_tcp"]),
      expected: z.object({
        transaction_id: z.int(),
        unit_id: z.int(),
        table: z.enum(["holding", "input"]),
        count: z.int(),
      }),
      buffer: z.string(),
      skipped: z.array(z.enum(["stale", "noise", "bad_crc"])),
      result: z.union([
        z.literal("incomplete"),
        z.object({ words: z.array(z.int()) }),
        z.object({ exception: z.int() }),
        z.object({ error: z.enum(["malformed_frame", "unexpected_response", "malformed_response"]) }),
      ]),
      rest: z.string(),
    }),
  ),
});

export const loadResponseFixture = () => responseFixture.parse(json("fixtures/modbus-read-responses.v1.json"));
const readResult = z.union([
  z.object({ words: z.array(z.int()) }),
  z.object({ exception: z.int() }),
  z.object({ error: z.string() }),
]);

const check = z.enum(["product_code", "serial", "energy_unit"]);

const identityFixture = z.object({
  format: z.literal("identity-checks/1"),
  reads: z.record(z.string(), z.array(z.tuple([check, z.string(), z.int(), z.int()]))),
  requests: z.record(z.string(), z.array(z.tuple([z.string(), z.int(), z.int(), z.array(check)]))),
  cases: z.array(
    z.object({
      why: z.string(),
      profile: z.string(),
      results: z.partialRecord(check, readResult),
      verdict: z.union([
        z.enum(["ok", "mismatch"]),
        z.object({ read_failed: z.union([z.object({ exception: z.int() }), z.object({ error: z.string() })]) }),
      ]),
      observed: z.strictObject({ serial: z.string().nullable(), product_code: z.string().nullable() }),
    }),
  ),
});

const firmwareName = z.enum(["software", "firmware_1", "firmware_2", "modbus_version"]);

const firmwareFixture = z.object({
  format: z.literal("firmware-names/1"),
  reads: z.record(z.string(), z.array(z.tuple([firmwareName, z.string(), z.int(), z.int()]))),
  cases: z.array(
    z.union([
      z.strictObject({ why: z.string(), profile: z.string(), name: firmwareName, words, value: z.string() }),
      z.strictObject({
        why: z.string(),
        profile: z.string(),
        name: firmwareName,
        words,
        refused: z.enum(["wrong_word_count", "empty", "not_printable"]),
      }),
    ]),
  ),
});

export const loadFirmwareFixture = () => firmwareFixture.parse(json("fixtures/firmware-names.v1.json"));
export const loadIdentityFixture = () => identityFixture.parse(json("fixtures/identity-checks.v1.json"));
export const loadDecodeFixture = () => decodeFixture.parse(json("fixtures/register-decode.v1.json"));
export const loadRequestFixture = () => requestFixture.parse(json("fixtures/modbus-read-requests.v1.json"));

const roundEvent = z.union([
  z.strictObject({ words }),
  z.strictObject({ exception: z.int() }),
  z.strictObject({
    failed: z.enum(["timeout", "closed", "unexpected_response", "malformed_response", "bad_crc", "malformed_frame"]),
  }),
  z.strictObject({ unreachable: z.string() }),
]);

const roundFixture = z.object({
  format: z.literal("read-round/1"),
  policy: z.strictObject({ retries: z.int(), busy_backoff_ms: z.int() }),
  cases: z.array(
    z.strictObject({
      why: z.string(),
      meters: z.array(z.strictObject({ unit_id: z.int(), profile: z.string() })),
      steps: z.array(
        z.strictObject({
          read: z.tuple([z.int(), z.enum(["holding", "input"]), z.int(), z.int()]),
          attempt: z.int(),
          wait_ms: z.int(),
          event: roundEvent,
        }),
      ),
      events: z.array(
        z.union([
          z.strictObject({
            reading: z.strictObject({
              unit_id: z.int(),
              register_key: z.string(),
              meter_serial: z.string(),
              product_code: z.string(),
              value: z.string(),
            }),
          }),
          z.strictObject({
            missed: z.strictObject({
              unit_id: z.int(),
              register_key: z.string(),
              meter_serial: z.string().nullable(),
              reason: z.string(),
              exception_code: z.int().nullable(),
              detail: z.string().nullable(),
              attempts: z.int(),
              raw_words: words.nullable(),
            }),
          }),
        ]),
      ),
    }),
  ),
});

export const loadRoundFixture = () => roundFixture.parse(json("fixtures/read-round.v1.json"));

const head = { profile: z.string(), profile_version: z.int() };
const localTime = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/);

const storedFixture = z.strictObject({
  format: z.literal("stored-decode/1"),
  description: z.string(),
  stamps: z.array(
    z.strictObject({
      ...head,
      field: z.enum(["meter_clock", "history.stamp", "snapshot.stamp", "load_survey.stamp"]),
      raw_words: words,
      meter_time: localTime,
      why: z.string(),
    }),
  ),
  masks: z.array(
    z.strictObject({
      ...head,
      field: z.enum(["history.mask", "snapshot.mask", "load_survey.mask"]),
      raw_words: words,
      named: z.array(z.strictObject({ bit: z.int(), register_key: z.string() })),
      unnamed: z.array(z.int()),
      why: z.string(),
    }),
  ),
  blocks: z.array(
    z.strictObject({
      ...head,
      store: z.enum(["history", "snapshot"]),
      stamp_words: words,
      mask_words: words.optional(),
      registers: z.record(z.string(), words),
      meter_time: localTime,
      entries: z.array(z.strictObject({ register_key: z.string(), value: z.string() })),
      unsupported: z.array(z.string()),
      not_finite: z.array(z.string()),
      why: z.string(),
    }),
  ),
  load_survey: z.array(
    z.strictObject({
      ...head,
      parameter: z.int(),
      register_key: z.string(),
      stamp_words: words,
      interval_words: words,
      clock_words: words.optional(),
      values_words: words,
      interval_s: z.int(),
      entries: z.array(z.strictObject({ meter_time: localTime, value: z.string() })),
      not_finite: z.array(localTime),
      not_ended: z.int(),
      why: z.string(),
    }),
  ),
  no_value: z.array(
    z.strictObject({
      ...head,
      field: z.string(),
      raw_words: words,
      error: z.enum(["wrong_word_count", "zero_interval", "interval_not_dividing_a_day"]),
      why: z.string(),
    }),
  ),
});

export const loadStoredFixture = () => storedFixture.parse(json("fixtures/stored-decode.v1.json"));
