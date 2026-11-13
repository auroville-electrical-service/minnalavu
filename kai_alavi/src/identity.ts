import type { Table } from "./pdu";
import type { Profile } from "./profile";
import type { Result } from "./result";

// The checks guard against a meter registered under the wrong model; they follow `alavi`'s
// `Alavi.Profile.Identity`.

export type Check = "product_code" | "energy_unit";

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

export type Verdict =
  | { readonly kind: "ok" }
  | { readonly kind: "mismatch"; readonly detail: string }
  | { readonly kind: "read_failed"; readonly check: Check; readonly failure: ReadFailure };

type Identity = Profile["identity"];

const illegalAddress = 2;
const passed: Verdict = { kind: "ok" };

// contract: test/identity.test.ts "identityReads"
export const identityReads = (identity: Identity): readonly IdentityRead[] => [
  ...(identity.product_code ? [{ check: "product_code" as const, ...pick(identity.product_code) }] : []),
  ...(identity.energy_unit ? [{ check: "energy_unit" as const, ...pick(identity.energy_unit), count: 1 }] : []),
];

const pick = (s: { table: Table; address: number; count?: number }) => ({
  table: s.table,
  address: s.address,
  count: s.count ?? 1,
});

// contract: test/identity.test.ts "identityVerdict"
export const identityVerdict = (identity: Identity, results: Readonly<Partial<Record<Check, ReadResult>>>): Verdict =>
  identityReads(identity).reduce<Verdict>((verdict, read) => {
    if (verdict.kind !== "ok") return verdict;
    const result = results[read.check];
    if (!result) throw new Error(`no result for the ${read.check} read`);
    return judge(identity, read.check, result);
  }, passed);

const judge = (identity: Identity, check: Check, result: ReadResult): Verdict => {
  const { product_code: product, energy_unit: unit } = identity;
  if (check === "energy_unit" && unit?.absent_ok && isException(result, illegalAddress)) return passed;
  if (!result.ok) return { kind: "read_failed", check, failure: result.error };
  if (check === "product_code" && product) return productCode(product.accept, result.value);
  if (check === "energy_unit" && unit) return energyUnit(unit, result.value);
  throw new Error(`no ${check} check in this identity`);
};

const isException = (result: ReadResult, code: number): boolean =>
  !result.ok && result.error.kind === "exception" && result.error.code === code;

const utf8 = new TextEncoder();

const productCode = (accept: readonly string[], words: readonly number[]): Verdict => {
  const code = trimmed(words.flatMap((w) => [w >> 8, w & 0xff]));
  const same = (a: Uint8Array): boolean => a.length === code.length && a.every((b, i) => b === code[i]);
  if (accept.some((c) => same(utf8.encode(c)))) return passed;
  const shown = JSON.stringify(new TextDecoder().decode(Uint8Array.from(code)));
  return { kind: "mismatch", detail: `product code ${shown}, expected one of ${accept.join(", ")}` };
};

const energyUnit = (
  unit: { table: Table; address: number; part: "high_byte" | "word"; expect: number },
  words: readonly number[],
): Verdict => {
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

// ASCII whitespace only: alavi's String.trim also strips Unicode whitespace, so this can only
// refuse a meter alavi accepts, never accept one it refuses.
const space = (b: number): boolean => b === 0x20 || (b >= 0x09 && b <= 0x0d);

const trimmed = (bytes: readonly number[]): readonly number[] => {
  const end = bytes.findLastIndex((b) => b !== 0) + 1;
  const unpadded = bytes.slice(0, end);
  const first = unpadded.findIndex((b) => !space(b));
  if (first === -1) return [];
  return unpadded.slice(first, unpadded.findLastIndex((b) => !space(b)) + 1);
};
