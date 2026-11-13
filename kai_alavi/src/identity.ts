import type { Table } from "./pdu";
import type { Profile } from "./profile";
import type { Result } from "./result";

// The checks guard against a meter registered under the wrong model and say what the meter
// reported; they follow `alavi`'s `Alavi.Profile.Identity`.

export type Check = "product_code" | "serial" | "energy_unit";

export interface IdentityRead {
  readonly check: Check;
  readonly table: Table;
  readonly address: number;
  readonly count: number;
}

export type ReadFailure =
  | { readonly kind: "exception"; readonly code: number }
  | { readonly kind: "failed"; readonly reason: string };

export type ReadResult = Result<readonly number[], ReadFailure>;

export type Outcome =
  | { readonly kind: "ok" }
  | { readonly kind: "mismatch"; readonly detail: string }
  | { readonly kind: "read_failed"; readonly check: Check; readonly failure: ReadFailure };

// What the meter reported, whatever the outcome: null where the profile has no such check, the
// read failed, or the text is empty or not printable ASCII.
export interface Observed {
  readonly serial: string | null;
  readonly product_code: string | null;
}

export interface Verdict {
  readonly outcome: Outcome;
  readonly observed: Observed;
}

type Identity = Profile["identity"];
type Results = Readonly<Partial<Record<Check, ReadResult>>>;

const illegalAddress = 2;
const passed: Outcome = { kind: "ok" };
const checks = ["product_code", "serial", "energy_unit"] as const;

// contract: test/identity.test.ts "identityReads"
export const identityReads = (identity: Identity): readonly IdentityRead[] =>
  checks.flatMap((check) => {
    const spec = identity[check];
    if (!spec) return [];
    return [{ check, table: spec.table, address: spec.address, count: "count" in spec ? spec.count : 1 }];
  });

// contract: test/identity.test.ts "identityVerdict"
export const identityVerdict = (identity: Identity, results: Results): Verdict => ({
  outcome: outcome(identity, results),
  observed: {
    serial: observe(identity.serial, results.serial),
    product_code: observe(identity.product_code, results.product_code),
  },
});

const outcome = (identity: Identity, results: Results): Outcome =>
  identityReads(identity).reduce<Outcome>((outcome, read) => {
    if (outcome.kind !== "ok") return outcome;
    return judge(identity, read.check, resultFor(results, read.check));
  }, passed);

const resultFor = (results: Results, check: Check): ReadResult => {
  const result = results[check];
  if (!result) throw new Error(`no result for the ${check} read`);
  return result;
};

const observe = (spec: object | undefined, result: ReadResult | undefined): string | null => {
  if (!spec) return null;
  if (!result) throw new Error("no result for a listed read");
  return result.ok ? printable(trimmed(bytesOf(result.value))) : null;
};

const judge = (identity: Identity, check: Check, result: ReadResult): Outcome => {
  const { product_code: product, energy_unit: unit } = identity;
  if (check === "energy_unit" && unit?.absent_ok && isException(result, illegalAddress)) return passed;
  if (!result.ok) return { kind: "read_failed", check, failure: result.error };
  if (check === "product_code" && product) return productCode(product.accept, result.value);
  if (check === "serial" && identity.serial) return serial(result.value);
  if (check === "energy_unit" && unit) return energyUnit(unit, result.value);
  throw new Error(`no ${check} check in this identity`);
};

const isException = (result: ReadResult, code: number): boolean =>
  !result.ok && result.error.kind === "exception" && result.error.code === code;

const utf8 = new TextEncoder();
const bytesOf = (words: readonly number[]): readonly number[] => words.flatMap((w) => [w >> 8, w & 0xff]);
const shown = (bytes: readonly number[]): string => JSON.stringify(new TextDecoder().decode(Uint8Array.from(bytes)));

const productCode = (accept: readonly string[], words: readonly number[]): Outcome => {
  const code = trimmed(bytesOf(words));
  const same = (a: Uint8Array): boolean => a.length === code.length && a.every((b, i) => b === code[i]);
  if (accept.some((c) => same(utf8.encode(c)))) return passed;
  return { kind: "mismatch", detail: `product code ${shown(code)}, expected one of ${accept.join(", ")}` };
};

const serial = (words: readonly number[]): Outcome => {
  const bytes = trimmed(bytesOf(words));
  return printable(bytes) === null
    ? { kind: "mismatch", detail: `serial ${shown(bytes)} is empty or not printable ASCII` }
    : passed;
};

const energyUnit = (
  unit: { table: Table; address: number; part: "high_byte" | "word"; expect: number },
  words: readonly number[],
): Outcome => {
  const [word] = words;
  if (words.length !== 1 || word === undefined) {
    return { kind: "mismatch", detail: `energy unit read gave ${words.length} words, expected 1` };
  }
  const code = unit.part === "high_byte" ? word >> 8 : word;
  return code === unit.expect
    ? passed
    : {
        kind: "mismatch",
        detail: `energy unit code ${code} at ${unit.table} ${unit.address}, expected ${unit.expect}`,
      };
};

const printable = (bytes: readonly number[]): string | null =>
  bytes.length > 0 && bytes.every((b) => b >= 0x20 && b <= 0x7e) ? String.fromCharCode(...bytes) : null;

// Trailing NULs, then surrounding ASCII whitespace: the bytes alavi trims.
const space = (b: number): boolean => b === 0x20 || (b >= 0x09 && b <= 0x0d);

const trimmed = (bytes: readonly number[]): readonly number[] => {
  const end = bytes.findLastIndex((b) => b !== 0) + 1;
  const unpadded = bytes.slice(0, end);
  const first = unpadded.findIndex((b) => !space(b));
  if (first === -1) return [];
  return unpadded.slice(first, unpadded.findLastIndex((b) => !space(b)) + 1);
};
