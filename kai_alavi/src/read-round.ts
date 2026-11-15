import {
  type Endpoint,
  type IdentifiedMeter,
  type Meter,
  type MissedRead,
  type MissReason,
  type Reading,
  readRegister,
} from "./batch";
import { wordCount } from "./decode";
import {
  type IdentityRead,
  type IdentityRequest,
  identityObserved,
  identityRequests,
  identityVerdict,
  type ReadFailure,
  type Results,
  splitReply,
} from "./identity";
import { type ReadRequest, readRequest, type Table } from "./pdu";
import type { Profile } from "./profile";
import { err, ok } from "./result";

// One read round of an endpoint's meters, with no I/O: the app makes each read the round asks for
// and passes back what came of it. Follows `alavi`'s poller (`Alavi.Poller`, `Alavi.Poller.Policy`)
// for one round, firmware names left out.

export interface RoundMeter {
  readonly unitId: number;
  readonly profile: Profile;
}

/** `retries`: further attempts after a failed one; `busyBackoffMs`: the wait before each retry after exception 05 or 06. */
export interface Policy {
  readonly retries: number;
  readonly busyBackoffMs: number;
}

/** A read that failed in transport, so that trying it again may help. */
export type Failure =
  | {
      readonly kind:
        | "timeout"
        | "closed"
        | "unexpected_response"
        | "malformed_response"
        | "bad_crc"
        | "malformed_frame";
    }
  | { readonly kind: "socket"; readonly detail: string };

/** What came of a read; `at` is the app's clock then. `unreachable`: no connection could be opened, so nothing was sent. */
export type ReadEvent =
  | { readonly kind: "reply"; readonly at: Date; readonly words: readonly number[] }
  | { readonly kind: "exception"; readonly at: Date; readonly code: number }
  | { readonly kind: "failed"; readonly at: Date; readonly failure: Failure }
  | { readonly kind: "unreachable"; readonly at: Date; readonly detail: string };

/** Send `request` to `unitId` once `waitMs` have passed, and pass back what came of it. */
export interface Read {
  readonly kind: "read";
  readonly unitId: number;
  readonly table: Table;
  readonly address: number;
  readonly count: number;
  readonly request: ReadRequest;
  readonly attempt: number;
  readonly waitMs: number;
}

export type Action = Read | { readonly kind: "done" };

export type Recorded =
  | { readonly kind: "reading"; readonly reading: Reading }
  | { readonly kind: "missed"; readonly missed: MissedRead };

type Pending =
  | {
      readonly kind: "identity";
      readonly requests: readonly IdentityRequest[];
      readonly alone: readonly IdentityRead[];
      readonly results: Results;
    }
  | { readonly kind: "registers"; readonly seen: IdentifiedMeter; readonly index: number };

/** `meters` starts with the one being read; `recorded` is every reading and missed read so far, in order. */
export interface Round {
  readonly endpoint: Endpoint;
  readonly policy: Policy;
  readonly meters: readonly RoundMeter[];
  readonly pending: Pending | null;
  readonly attempt: number;
  readonly waitMs: number;
  readonly recorded: readonly Recorded[];
}

export interface RoundStep {
  readonly round: Round;
  readonly action: Action;
}

type Decision =
  | { readonly kind: "words"; readonly words: readonly number[] }
  | { readonly kind: "retry"; readonly waitMs: number }
  | { readonly kind: "skip_read"; readonly reason: { readonly kind: "exception"; readonly code: number } }
  | { readonly kind: "skip_meter"; readonly reason: MissReason; readonly down: boolean };

const busy = [0x05, 0x06];
// The gateway has already waited for the meter, so a retry only costs bus time.
const gateway = [0x0a, 0x0b];

// contract: test/read-round.test.ts "startRound"
export const startRound = (endpoint: Endpoint, meters: readonly RoundMeter[], policy: Policy): RoundStep =>
  begin({ endpoint, policy, meters, pending: null, attempt: 1, waitMs: 0, recorded: [] });

// contract: test/read-round.test.ts "nextRead"
// Throws on a round that is done, and on a reply whose length is not the count asked for.
export const nextRead = (round: Round, event: ReadEvent): RoundStep => {
  const { pending } = round;
  if (!pending) throw new Error("the round is done: no read is outstanding");
  const decision = decide(event, round.attempt, round.policy);
  switch (decision.kind) {
    case "retry":
      return ask({ ...round, attempt: round.attempt + 1, waitMs: decision.waitMs });
    case "skip_meter":
      return skipMeter(round, pending, decision, event.at);
    case "words":
      checkLength(round, pending, decision.words);
      return answered(round, pending, decision, event.at);
    case "skip_read":
      return answered(round, pending, decision, event.at);
    default: {
      const unknown: never = decision;
      return unknown;
    }
  }
};

const decide = (event: ReadEvent, attempt: number, policy: Policy): Decision => {
  const again = attempt <= policy.retries;
  switch (event.kind) {
    case "reply":
      return { kind: "words", words: event.words };
    case "exception": {
      const reason = { kind: "exception", code: event.code } as const;
      if (gateway.includes(event.code)) return { kind: "skip_meter", reason, down: false };
      if (busy.includes(event.code)) {
        return again ? { kind: "retry", waitMs: policy.busyBackoffMs } : { kind: "skip_meter", reason, down: false };
      }
      return { kind: "skip_read", reason };
    }
    case "failed":
      return again ? { kind: "retry", waitMs: 0 } : { kind: "skip_meter", reason: event.failure, down: false };
    case "unreachable":
      return { kind: "skip_meter", reason: { kind: "unreachable", detail: event.detail }, down: true };
    default: {
      const unknown: never = event;
      return unknown;
    }
  }
};

const meterOf = (round: Round): RoundMeter => {
  const [meter] = round.meters;
  if (!meter) throw new Error("no meter left in the round");
  return meter;
};

const begin = (round: Round): RoundStep => {
  const [meter] = round.meters;
  if (!meter) return { round: { ...round, pending: null }, action: { kind: "done" } };
  const pending: Pending = {
    kind: "identity",
    requests: identityRequests(meter.profile.identity),
    alone: [],
    results: {},
  };
  return ask({ ...round, pending, attempt: 1, waitMs: 0 });
};

const target = (pending: Pending, meter: RoundMeter): { table: Table; address: number; count: number } => {
  if (pending.kind === "registers") {
    const register = meter.profile.registers[pending.index];
    if (!register) throw new Error(`no register ${pending.index} in ${meter.profile.profile}`);
    return { table: register.table, address: register.address, count: wordCount(register.type) };
  }
  const read = pending.alone[0] ?? pending.requests[0];
  if (!read) throw new Error("no identity read left to make");
  return read;
};

// A request `readRequest` refuses is a profile that runs past the register space; alavi records it
// as a missed read (invalid_request), which no valid profile reaches.
const ask = (round: Round): RoundStep => {
  const { pending } = round;
  if (!pending) throw new Error("ask on a round that is done");
  const meter = meterOf(round);
  const { table, address, count } = target(pending, meter);
  const request = readRequest(table, address, count);
  if (!request.ok) throw new Error(`${meter.profile.profile}: no read request for ${table} ${address}+${count}`);
  const read: Read = {
    kind: "read",
    unitId: meter.unitId,
    table,
    address,
    count,
    request: request.value,
    attempt: round.attempt,
    waitMs: round.waitMs,
  };
  return { round, action: read };
};

const checkLength = (round: Round, pending: Pending, words: readonly number[]): void => {
  const { count } = target(pending, meterOf(round));
  if (words.length !== count) throw new Error(`a reply of ${words.length} words to a read of ${count}`);
};

type Answer = Extract<Decision, { kind: "words" | "skip_read" }>;

const answered = (round: Round, pending: Pending, answer: Answer, at: Date): RoundStep =>
  pending.kind === "identity" ? identified(round, pending, answer, at) : registered(round, pending, answer, at);

const resultOf = (answer: Answer) => (answer.kind === "words" ? ok(answer.words) : err(answer.reason));

const identified = (
  round: Round,
  pending: Extract<Pending, { kind: "identity" }>,
  answer: Answer,
  at: Date,
): RoundStep => {
  const [alone, ...restAlone] = pending.alone;
  const [request, ...restRequests] = pending.requests;
  const next: Extract<Pending, { kind: "identity" }> = alone
    ? { ...pending, alone: restAlone, results: { ...pending.results, [alone.check]: resultOf(answer) } }
    : request && request.reads.length > 1
      ? merged(pending, request, restRequests, answer)
      : single(pending, request, restRequests, answer);
  if (next.alone.length > 0 || next.requests.length > 0) return ask({ ...round, pending: next, attempt: 1, waitMs: 0 });
  return judged(round, next.results, at);
};

// A meter refuses the whole request if any register in it is missing (an Elite 440 without the
// unit setting), so each read is then made alone, as if never merged.
const merged = (
  pending: Extract<Pending, { kind: "identity" }>,
  request: IdentityRequest,
  rest: readonly IdentityRequest[],
  answer: Answer,
): Extract<Pending, { kind: "identity" }> =>
  answer.kind === "words"
    ? { ...pending, requests: rest, results: { ...pending.results, ...splitReply(request, answer.words) } }
    : { ...pending, requests: rest, alone: request.reads };

const single = (
  pending: Extract<Pending, { kind: "identity" }>,
  request: IdentityRequest | undefined,
  rest: readonly IdentityRequest[],
  answer: Answer,
): Extract<Pending, { kind: "identity" }> => {
  const [read] = request?.reads ?? [];
  if (!read) throw new Error("no identity read outstanding");
  return { ...pending, requests: rest, results: { ...pending.results, [read.check]: resultOf(answer) } };
};

const judged = (round: Round, results: Results, at: Date): RoundStep => {
  const meter = meterOf(round);
  const { outcome, observed } = identityVerdict(meter.profile.identity, results);
  switch (outcome.kind) {
    case "ok": {
      const { serial, product_code: productCode } = observed;
      if (serial === null || productCode === null) {
        throw new Error(`${meter.profile.profile} passed its identity check without a serial and product code`);
      }
      const seen: IdentifiedMeter = { ...meterRef(round.endpoint, meter, serial), serial, productCode };
      return ask({ ...round, pending: { kind: "registers", seen, index: 0 }, attempt: 1, waitMs: 0 });
    }
    case "mismatch":
      return nextMeter(missAll(round, observed.serial, { kind: "profile_mismatch", detail: outcome.detail }, 0, at));
    case "read_failed":
      return nextMeter(missAll(round, observed.serial, missReason(outcome.failure), 0, at));
    default: {
      const unknown: never = outcome;
      return unknown;
    }
  }
};

// Only exceptions reach the identity results: every other failure misses the meter first.
const missReason = (failure: ReadFailure): MissReason => {
  if (failure.kind === "exception") return failure;
  throw new Error(`an identity read failed with ${failure.reason}, which the round never records`);
};

const registered = (
  round: Round,
  pending: Extract<Pending, { kind: "registers" }>,
  answer: Answer,
  at: Date,
): RoundStep => {
  const register = meterOf(round).profile.registers[pending.index];
  if (!register) throw new Error(`no register ${pending.index}`);
  const event: Recorded =
    answer.kind === "words"
      ? recordedOf(readRegister(pending.seen, register, answer.words, at, round.attempt))
      : { kind: "missed", missed: missedRead(pending.seen, register.key, answer.reason, round.attempt, at) };
  const done = { ...round, recorded: [...round.recorded, event] };
  const index = pending.index + 1;
  if (index >= meterOf(round).profile.registers.length) return nextMeter(done);
  return ask({ ...done, pending: { ...pending, index }, attempt: 1, waitMs: 0 });
};

const recordedOf = (result: ReturnType<typeof readRegister>): Recorded =>
  result.ok ? { kind: "reading", reading: result.value } : { kind: "missed", missed: result.error };

const skipMeter = (
  round: Round,
  pending: Pending,
  decision: Extract<Decision, { kind: "skip_meter" }>,
  at: Date,
): RoundStep => {
  const missed = missFrom(round, pending, decision.reason, at);
  if (!decision.down) return nextMeter(missed);
  const [, ...later] = missed.meters;
  const untried = later.flatMap((meter) =>
    missMeter(round.endpoint, meter, { serial: null, reason: decision.reason, attempts: 0, at }),
  );
  return {
    round: { ...missed, recorded: [...missed.recorded, ...untried], meters: [], pending: null },
    action: { kind: "done" },
  };
};

// Every register not yet recorded: the attempts made count on the first, 0 on the rest.
const missFrom = (round: Round, pending: Pending, reason: MissReason, at: Date): Round => {
  const meter = meterOf(round);
  if (pending.kind === "identity") {
    const { serial } = identityObserved(meter.profile.identity, pending.results);
    return missAll(round, serial, reason, round.attempt, at);
  }
  const left = meter.profile.registers.slice(pending.index);
  const missed = left.map(
    (r, i): Recorded => ({
      kind: "missed",
      missed: missedRead(pending.seen, r.key, reason, i === 0 ? round.attempt : 0, at),
    }),
  );
  return { ...round, recorded: [...round.recorded, ...missed] };
};

const missAll = (round: Round, serial: string | null, reason: MissReason, attempts: number, at: Date): Round => ({
  ...round,
  recorded: [...round.recorded, ...missMeter(round.endpoint, meterOf(round), { serial, reason, attempts, at })],
});

const missMeter = (
  endpoint: Endpoint,
  meter: RoundMeter,
  miss: { serial: string | null; reason: MissReason; attempts: number; at: Date },
): Recorded[] => {
  const ref = meterRef(endpoint, meter, miss.serial);
  return meter.profile.registers.map((r, i) => ({
    kind: "missed",
    missed: missedRead(ref, r.key, miss.reason, i === 0 ? miss.attempts : 0, miss.at),
  }));
};

const nextMeter = (round: Round): RoundStep => begin({ ...round, meters: round.meters.slice(1) });

const meterRef = (endpoint: Endpoint, meter: RoundMeter, serial: string | null): Meter => ({
  endpoint,
  unitId: meter.unitId,
  serial,
  profile: meter.profile.profile,
  profileVersion: meter.profile.version,
});

const missedRead = (meter: Meter, registerKey: string, reason: MissReason, attempts: number, at: Date): MissedRead => ({
  meter,
  registerKey,
  at,
  reason,
  attempts,
});
