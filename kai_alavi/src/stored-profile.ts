import { z } from "zod";

// Where a meter keeps the entries a copy reads, parsed from a profile's `meter_clock` and `stored`
// sections; follows `alavi`'s `Alavi.Profile.Stored`. Every address is a holding register's PDU
// address. A selector is named, never addressed: this package writes nothing to a meter.

const source = z.string().regex(/^[a-z0-9][a-z0-9_-]*$/, "a source is an ID: lowercase letters, digits, - and _");
const cited = { source, verified_on_device: z.iso.date().nullable() };
const address = z.int().min(0).max(0xffff);
const holding = z.literal("holding");
const wordOrder = z.enum(["high_first", "low_first"]);
const unit = z.enum(["Wh", "kWh", "varh", "kvarh", "VAh", "kVAh", "V", "A", "Hz"]);
const kind = z.enum(["cumulative", "interval", "demand", "instantaneous"]);

// The meter's local time: no zone, whole seconds, a date-time that exists.
const localTime = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/, "must be a local date-time, YYYY-MM-DDTHH:MM:SS")
  .refine((t) => !Number.isNaN(Date.parse(`${t}Z`)) && new Date(`${t}Z`).toISOString().startsWith(t), {
    message: "must be a date-time that exists",
  });

/** An unsigned 32-bit count of seconds since `epoch`, the meter's local time. */
const stamp = z.strictObject({
  table: holding,
  address,
  type: z.literal("u32"),
  word_order: wordOrder,
  epoch: localTime,
  ...cited,
});

const count = z.strictObject({ table: holding, address, type: z.literal("u16"), ...cited });

// One word has no word order.
const mask = z.discriminatedUnion("type", [
  z.strictObject({ table: holding, address, type: z.literal("u16"), ...cited }),
  z.strictObject({ table: holding, address, type: z.enum(["u32", "u64"]), word_order: wordOrder, ...cited }),
]);

const register = z.strictObject({
  key: z.string().min(1),
  table: holding,
  address,
  type: z.literal("f32"),
  word_order: wordOrder,
  unit,
  kind,
  mask_bit: z.int().min(0).max(63).optional(),
  ...cited,
});

const parameter = z.strictObject({ number: z.int().min(0).max(63), key: z.string().min(1), unit, kind, ...cited });

const unique = (values: readonly unknown[]): boolean => new Set(values).size === values.length;

// The kind rules the store's catalog also enforces: a load-survey quantity is never cumulative,
// and no other store's is per interval.
const block = <S extends "history" | "snapshot">(store: S) =>
  z
    .strictObject({
      selector: z.literal(store),
      available: count,
      stamp,
      mask: mask.optional(),
      registers: z.array(register).min(1),
    })
    .refine((b) => unique(b.registers.map((r) => r.key)), { message: "a register key appears more than once" })
    .refine((b) => unique(b.registers.flatMap((r) => (r.mask_bit === undefined ? [] : [r.mask_bit]))), {
      message: "a mask bit appears more than once",
    })
    .refine((b) => b.registers.every((r) => (r.mask_bit === undefined) === (b.mask === undefined)), {
      message: "every register has a mask_bit exactly when there is a mask",
    })
    .refine((b) => b.registers.every((r) => r.kind !== "interval"), {
      message: "only the load survey is per interval",
    });

// A register that must read `value` for the survey the selectors show to be the one the section
// describes: which logger they show, or whether energy is kept per interval.
const requirement = z.strictObject({
  key: z.string().min(1),
  table: holding,
  address,
  type: z.literal("u16"),
  value: z.int().min(0).max(0xffff),
  ...cited,
});

const survey = z
  .strictObject({
    selectors: z.strictObject({ day: z.literal("load_survey_day"), parameter: z.literal("load_survey_parameter") }),
    requires: z.array(requirement).min(1).optional(),
    available: count,
    interval: z.strictObject({ table: holding, address, type: z.literal("u16"), unit: z.literal("min"), ...cited }),
    stamp,
    mask,
    values: z.strictObject({
      table: holding,
      address,
      type: z.literal("f32"),
      word_order: wordOrder,
      per_request: z.int().min(1).max(62),
      ...cited,
    }),
    parameters: z.array(parameter).min(1),
  })
  .refine((s) => unique((s.requires ?? []).map((r) => r.key)), { message: "a requires key appears more than once" })
  .refine((s) => unique(s.parameters.map((p) => p.key)), { message: "a parameter key appears more than once" })
  .refine((s) => unique(s.parameters.map((p) => p.number)), { message: "a parameter number appears more than once" })
  .refine((s) => s.parameters.every((p) => p.kind !== "cumulative"), {
    message: "a load-survey quantity cannot be cumulative",
  });

export const meterClock = stamp;

export const stored = z
  .strictObject({ history: block("history"), snapshot: block("snapshot"), load_survey: survey })
  .readonly();

export type Stamp = z.infer<typeof stamp>;
export type Mask = z.infer<typeof mask>;
export type StoredRegister = z.infer<typeof register>;
export type Block = z.infer<ReturnType<typeof block>>;
export type Survey = z.infer<typeof survey>;
export type Parameter = z.infer<typeof parameter>;
export type Stored = z.infer<typeof stored>;

/** Every source a `meter_clock` and `stored` section cite. */
export const storedSources = (clock: Stamp | undefined, s: Stored | undefined): string[] => [
  ...(clock ? [clock.source] : []),
  ...(s
    ? [s.history, s.snapshot].flatMap((b) => [
        b.available.source,
        b.stamp.source,
        ...(b.mask ? [b.mask.source] : []),
        ...b.registers.map((r) => r.source),
      ])
    : []),
  ...(s
    ? [
        ...(s.load_survey.requires ?? []),
        s.load_survey.available,
        s.load_survey.interval,
        s.load_survey.stamp,
        s.load_survey.mask,
        s.load_survey.values,
        ...s.load_survey.parameters,
      ].map((e) => e.source)
    : []),
];
