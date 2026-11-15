import type { Table } from "./pdu";
import type { Profile } from "./profile";
import { ok, type Result } from "./result";
import { bytesOf, printable, trimmed } from "./text";

// The checks guard against a meter registered under the wrong model and say what the meter
// reported; they follow `alavi`'s `Alavi.Profile.Identity`.

export type Check = "product_code" | "serial" | "energy_unit";

export interface IdentityRead {
  readonly check: Check;
  readonly table: Table;
  readonly address: number;
  readonly count: number;
}

// One request covering `reads`, in the order `identityReads` lists them.
export interface IdentityRequest {
  readonly table: Table;
  readonly address: number;
  readonly count: number;
  readonly reads: readonly IdentityRead[];
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
export type Results = Readonly<Partial<Record<Check, ReadResult>>>;

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

// The widest run of unread registers seen answered inside one identity request: 15 on an Elite
// 440 (4-18) and 14 on an Elite 500 (2007-2020), one meter each, 2026-11-14. The 500 refused a
// request across 1958-1998 (41). Follows `alavi`'s `Alavi.Profile.Identity.requests/1`.
const maxGap = 15;
const maxCount = 125;

const end = (r: { readonly address: number; readonly count: number }): number => r.address + r.count;

const joins = (group: readonly IdentityRead[], read: IdentityRead): boolean => {
  const [first] = group;
  if (!first || first.table !== read.table) return false;
  const last = Math.max(...group.map(end));
  return read.address - last <= maxGap && end(read) - first.address <= maxCount;
};

const asRequest = (group: readonly IdentityRead[], reads: readonly IdentityRead[]): IdentityRequest => {
  const [first] = group;
  if (!first) throw new Error("an empty group of identity reads");
  const last = Math.max(...group.map(end));
  return {
    table: first.table,
    address: first.address,
    count: last - first.address,
    reads: reads.filter((r) => group.includes(r)),
  };
};

// contract: test/identity.test.ts "identityRequests"
// Reads in one table join a request when at most `maxGap` unread registers lie between them and
// it stays within `maxCount` registers; in the order of each request's first read.
export const identityRequests = (identity: Identity): readonly IdentityRequest[] => {
  const reads = identityReads(identity);
  const sorted = [...reads].sort((a, b) => a.table.localeCompare(b.table) || a.address - b.address);
  const groups: IdentityRead[][] = [];
  for (const read of sorted) {
    const current = groups.at(-1);
    if (current && joins(current, read)) current.push(read);
    else groups.push([read]);
  }
  const position = (r: IdentityRequest): number => (r.reads[0] ? reads.indexOf(r.reads[0]) : -1);
  return groups.map((g) => asRequest(g, reads)).sort((a, b) => position(a) - position(b));
};

// contract: test/identity.test.ts "splitReply"
// Each read's words, out of a reply to `request`.
export const splitReply = (request: IdentityRequest, words: readonly number[]): Results =>
  Object.fromEntries(
    request.reads.map((r) => [r.check, ok(words.slice(r.address - request.address, end(r) - request.address))]),
  );

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

// contract: test/identity.test.ts "identityObserved"
// What the meter reported in reads cut short: null too for a read not made.
export const identityObserved = (identity: Identity, results: Results): Observed => ({
  serial: identity.serial && results.serial ? text(results.serial) : null,
  product_code: identity.product_code && results.product_code ? text(results.product_code) : null,
});

const text = (result: ReadResult): string | null => (result.ok ? printable(trimmed(bytesOf(result.value))) : null);

const observe = (spec: object | undefined, result: ReadResult | undefined): string | null => {
  if (!spec) return null;
  if (!result) throw new Error("no result for a listed read");
  return text(result);
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
