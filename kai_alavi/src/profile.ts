import { z } from "zod";
import { err, ok, type Result } from "./result";

const text = z.string().min(1);
// An ID from the profile's `sources`; what each ID stands for is recorded outside the repo.
const source = z.string().regex(/^[a-z0-9][a-z0-9_-]*$/, "a source is an ID: lowercase letters, digits, - and _");
const table = z.enum(["holding", "input"]);
const address = z.int().min(0).max(0xffff);

const register = z
  .object({
    key: text,
    table,
    address,
    type: z.enum(["u16", "i16", "u32", "i32", "u64", "f32", "f64"]),
    word_order: z.enum(["high_first", "low_first"]),
    // The decoded value's precision; see `decode.ts`.
    decimals: z.int().min(0).max(9),
    unit: z.enum(["Wh", "kWh", "varh", "kvarh"]),
    source: source.nullable(),
    placeholder: z.boolean(),
    verified_on_device: z.iso.date().nullable(),
  })
  .readonly()
  .refine((r) => r.source !== null || r.placeholder, {
    message: "source is null but the entry is not marked placeholder",
  });

const identity = z.strictObject({
  product_code: z
    .strictObject({ table, address, count: z.int().min(1).max(125), accept: z.array(text).min(1), source })
    .optional(),
  energy_unit: z
    .strictObject({
      table,
      address,
      part: z.enum(["high_byte", "word"]),
      expect: z.int().min(0).max(0xffff),
      absent_ok: z.boolean(),
      source,
    })
    .optional(),
});

const usedSources = (p: {
  readonly identity: {
    readonly product_code?: { readonly source: string } | undefined;
    readonly energy_unit?: { readonly source: string } | undefined;
  };
  readonly registers: readonly { readonly source: string | null }[];
}): string[] => [
  ...[p.identity.product_code, p.identity.energy_unit].flatMap((check) => (check ? [check.source] : [])),
  ...p.registers.flatMap((r) => (r.source === null ? [] : [r.source])),
];

const profile = z
  .object({
    schema_version: z.literal(1),
    profile: text,
    models: z.array(z.string()).min(1),
    sources: z.array(source).min(1),
    identity,
    registers: z.array(register).min(1),
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
export type DataType = Register["type"];
export type WordOrder = Register["word_order"];

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
