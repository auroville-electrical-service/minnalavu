import { z } from "zod";
import { err, ok, type Result } from "./result";
import { meterClock, stored, storedSources } from "./stored-profile";

const text = z.string().min(1);
// An ID from the profile's `sources`; what each ID stands for is recorded outside the repo.
const source = z.string().regex(/^[a-z0-9][a-z0-9_-]*$/, "a source is an ID: lowercase letters, digits, - and _");
const table = z.enum(["holding", "input"]);
const address = z.int().min(0).max(0xffff);
const count = z.int().min(1).max(125);
const verified_on_device = z.iso.date().nullable();
// What a product code read must be for the poller to file it: alavi's rule too.
const printable = z.string().regex(/^[\x20-\x7e]+$/, "must be non-empty printable ASCII");

const integerType = z.enum(["u16", "i16", "u32", "i32", "u64"]);
const floatType = z.enum(["f32", "f64"]);

const entry = {
  key: text,
  table,
  address,
  word_order: z.enum(["high_first", "low_first"]),
  unit: z.enum(["Wh", "kWh", "varh", "kvarh"]),
  kind: z.enum(["cumulative", "interval", "demand", "instantaneous"]),
  source: source.nullable(),
  placeholder: z.boolean(),
  verified_on_device,
};

// An integer's value is the raw integer over 10^decimals; a float's needs no precision (`decode.ts`).
const register = z
  .discriminatedUnion("type", [
    z.object({ ...entry, type: integerType, decimals: z.int().min(0).max(9) }),
    z.object({
      ...entry,
      type: floatType,
      decimals: z.never({ error: "decimals is for integer registers: a float has none" }).optional(),
    }),
  ])
  .readonly()
  .refine((r) => r.source !== null || r.placeholder, {
    message: "source is null but the entry is not marked placeholder",
  });

const identity = z.strictObject({
  product_code: z
    .strictObject({ table, address, count, accept: z.array(printable).min(1), source, verified_on_device })
    .optional(),
  serial: z.strictObject({ table, address, count, source, verified_on_device }).optional(),
  energy_unit: z
    .strictObject({
      table,
      address,
      part: z.enum(["high_byte", "word"]),
      expect: z.int().min(0).max(0xffff),
      absent_ok: z.boolean(),
      source,
      verified_on_device,
    })
    .optional(),
});

// Informational only: no accept or expect, so a names read can never gate or label a reading.
const nameEntry = z.strictObject({ table, address, count, type: z.enum(["ascii", "hex"]), source, verified_on_device });
const firmware = z.strictObject({
  software: nameEntry,
  firmware_1: nameEntry,
  firmware_2: nameEntry,
  modbus_version: nameEntry,
});

const usedSources = (p: {
  readonly identity: {
    readonly product_code?: { readonly source: string } | undefined;
    readonly serial?: { readonly source: string } | undefined;
    readonly energy_unit?: { readonly source: string } | undefined;
  };
  readonly firmware?: Readonly<Record<string, { readonly source: string }>> | undefined;
  readonly registers: readonly { readonly source: string | null }[];
  readonly meter_clock?: Parameters<typeof storedSources>[0];
  readonly stored?: Parameters<typeof storedSources>[1];
}): string[] => [
  ...[p.identity.product_code, p.identity.serial, p.identity.energy_unit].flatMap((check) =>
    check ? [check.source] : [],
  ),
  ...Object.values(p.firmware ?? {}).map((name) => name.source),
  ...p.registers.flatMap((r) => (r.source === null ? [] : [r.source])),
  ...storedSources(p.meter_clock, p.stored),
];

const profile = z
  .object({
    schema_version: z.literal(1),
    profile: text,
    // Cited by every reading decoded under it; the batch schema's bound, so it survives a JSON number.
    version: z.int().min(1).max(Number.MAX_SAFE_INTEGER),
    models: z.array(z.string()).min(1),
    sources: z.array(source).min(1),
    identity,
    firmware: firmware.optional(),
    registers: z.array(register).min(1),
    meter_clock: meterClock.optional(),
    stored: stored.optional(),
  })
  .readonly()
  .refine((p) => new Set(p.registers.map((r) => r.key)).size === p.registers.length, {
    message: "a register key appears more than once",
  })
  .refine((p) => new Set(p.sources).size === p.sources.length, { message: "sources lists an ID more than once" })
  .refine((p) => usedSources(p).every((id) => p.sources.includes(id)), {
    message: "a source is not in sources",
  });

export type Profile = z.infer<typeof profile>;
export type Register = z.infer<typeof register>;
export type Firmware = z.infer<typeof firmware>;
export type FirmwareName = keyof Firmware;
export type NameEntry = z.infer<typeof nameEntry>;
export type IntegerType = z.infer<typeof integerType>;
export type FloatType = z.infer<typeof floatType>;
export type DataType = Register["type"];
export type WordOrder = Register["word_order"];
export type Kind = Register["kind"];

// contract: test/profile.test.ts "parseProfile"
// Follows `alavi`'s `Alavi.Profile.parse/1`. One difference no test can reach: of a key given twice,
// `JSON.parse` keeps the last value where alavi keeps the first.
export const parseProfile = (json: unknown): Result<Profile, string> => {
  const parsed = profile.safeParse(json);
  return parsed.success ? ok(parsed.data) : err(z.prettifyError(parsed.error));
};

export const findRegister = (p: Pick<Profile, "registers">, key: string): Result<Register, "unknown_register"> => {
  const found = p.registers.find((r) => r.key === key);
  return found ? ok(found) : err("unknown_register");
};
