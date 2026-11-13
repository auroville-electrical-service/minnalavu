import { type DecodeError, decodeValue } from "./decode";
import type { Register } from "./profile";
import { err, ok, type Result } from "./result";

// A `batch.v1`, shaped as `alavi`'s `Alavi.Wire` shapes it. It carries no collector id: the
// server knows the collector from the token.

export interface Endpoint {
  readonly host: string;
  readonly port: number;
}

/** A meter as the collector observes it in one round. */
export interface Meter {
  readonly endpoint: Endpoint;
  readonly unitId: number;
  /** The serial the meter reported this round, never one configured; null when none was read. */
  readonly serial: string | null;
  readonly profile: string;
}

/** A meter whose identity was read and passed this round: only such a meter has readings. */
export interface IdentifiedMeter extends Meter {
  readonly serial: string;
  /** The product code the meter reported this round. */
  readonly productCode: string;
}

export interface Reading {
  readonly meter: IdentifiedMeter;
  readonly registerKey: string;
  /** The collector's clock when the reply arrived. */
  readonly at: Date;
  readonly rawWords: readonly number[];
  /** A decimal string, never a number. */
  readonly value: string;
  readonly unit: Register["unit"];
}

export type MissReason =
  | { readonly kind: "exception"; readonly code: number }
  | {
      readonly kind:
        | "timeout"
        | "closed"
        | "invalid_request"
        | "unexpected_response"
        | "malformed_response"
        | "bad_crc"
        | "malformed_frame";
    }
  | { readonly kind: "socket" | "unreachable" | "profile_mismatch"; readonly detail: string }
  | { readonly kind: "decode"; readonly error: DecodeError; readonly rawWords: readonly number[] };

export interface MissedRead {
  readonly meter: Meter;
  readonly registerKey: string;
  readonly at: Date;
  readonly reason: MissReason;
  /** 0 means the read was not tried: the meter or endpoint was already known unreachable. */
  readonly attempts: number;
}

/** The collector's clock status when every event in the batch was recorded. */
export interface Clock {
  readonly source: "ntp" | "rtc" | "unsynced";
  readonly lastSyncAt: Date | null;
}

/** The collector's buffer when the batch was sent, this batch included. */
export interface Backlog {
  readonly events: number;
  readonly bytes: number;
  readonly batches: number;
  readonly oldest: Date | null;
  readonly maxBytes: number;
  readonly refused: number;
  readonly discardedFiles: number;
  readonly quarantined: number;
}

export interface Batch {
  readonly id: string;
  readonly sentAt: Date;
  readonly clock: Clock;
  readonly backlog: Backlog;
  readonly readings: readonly Reading[];
  readonly missedReads: readonly MissedRead[];
}

// contract: test/batch.test.ts "readRegister"
export const readRegister = (
  meter: IdentifiedMeter,
  register: Pick<Register, "key" | "type" | "word_order" | "decimals" | "unit">,
  words: readonly number[],
  at: Date,
  attempts: number,
): Result<Reading, MissedRead> => {
  const decoded = decodeValue(register, words);
  const base = { meter, registerKey: register.key, at };
  return decoded.ok
    ? ok({ ...base, rawWords: words, value: decoded.value, unit: register.unit })
    : err({ ...base, reason: { kind: "decode", error: decoded.error, rawWords: words }, attempts });
};

/** Whole seconds are written without a fraction; alavi writes microseconds. Both are date-times. */
const iso = (d: Date): string => d.toISOString().replace(".000Z", "Z");

const maxDetail = 200;

// The schema counts code points; slicing UTF-16 units could leave half a surrogate pair, which
// PostgreSQL's jsonb refuses, holding back the whole batch.
const cut = (detail: string): string => Array.from(detail).slice(0, maxDetail).join("");

const meterJson = (meter: Meter, registerKey: string, at: Date) => ({
  endpoint: { host: meter.endpoint.host, port: meter.endpoint.port },
  unit_id: meter.unitId,
  meter_serial: meter.serial,
  profile: meter.profile,
  register_key: registerKey,
  timestamp: iso(at),
});

const readingJson = (r: Reading) => ({
  ...meterJson(r.meter, r.registerKey, r.at),
  product_code: r.meter.productCode,
  raw_words: [...r.rawWords],
  value: r.value,
  unit: r.unit,
});

const reasonJson = (reason: MissReason) => {
  switch (reason.kind) {
    case "exception":
      return { reason: "exception", exception_code: reason.code, detail: null, raw_words: null };
    case "socket":
    case "unreachable":
    case "profile_mismatch":
      return { reason: reason.kind, exception_code: null, detail: cut(reason.detail), raw_words: null };
    case "decode":
      return { reason: "decode", exception_code: null, detail: reason.error, raw_words: [...reason.rawWords] };
    default:
      return { reason: reason.kind, exception_code: null, detail: null, raw_words: null };
  }
};

const missedJson = (m: MissedRead) => {
  const { raw_words, ...reason } = reasonJson(m.reason);
  return { ...meterJson(m.meter, m.registerKey, m.at), ...reason, attempts: m.attempts, raw_words };
};

// contract: test/batch.test.ts "batchJson"
export const batchJson = (b: Batch) => ({
  schema_version: 1,
  batch_id: b.id,
  sent_at: iso(b.sentAt),
  clock: { source: b.clock.source, last_sync_at: b.clock.lastSyncAt && iso(b.clock.lastSyncAt) },
  backlog: {
    events: b.backlog.events,
    bytes: b.backlog.bytes,
    batches: b.backlog.batches,
    oldest: b.backlog.oldest && iso(b.backlog.oldest),
    max_bytes: b.backlog.maxBytes,
    refused: b.backlog.refused,
    discarded_files: b.backlog.discardedFiles,
    quarantined: b.backlog.quarantined,
  },
  readings: b.readings.map(readingJson),
  missed_reads: b.missedReads.map(missedJson),
});
