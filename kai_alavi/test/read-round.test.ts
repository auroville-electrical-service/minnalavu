import { describe, expect, test } from "bun:test";
import {
  type Batch,
  batchJson,
  nextRead,
  type ReadEvent,
  type Recorded,
  type RoundStep,
  startRound,
} from "../src/index";
import { loadProfiles, loadRoundFixture } from "./contract";

const fixture = loadRoundFixture();
const profiles = loadProfiles();
const endpoint = { host: "192.0.2.1", port: 502 };
const policy = { retries: fixture.policy.retries, busyBackoffMs: fixture.policy.busy_backoff_ms };
const at = new Date("2026-11-15T00:00:00Z");

const profile = (name: string) => {
  const found = profiles.get(name);
  if (!found) throw new Error(`no profile ${name}`);
  return found;
};

const meters = (ms: readonly { unit_id: number; profile: string }[]) =>
  ms.map((m) => ({ unitId: m.unit_id, profile: profile(m.profile) }));

type FixtureEvent = (typeof fixture.cases)[number]["steps"][number]["event"];

const event = (e: FixtureEvent): ReadEvent => {
  if ("words" in e) return { kind: "reply", at, words: e.words };
  if ("exception" in e) return { kind: "exception", at, code: e.exception };
  if ("failed" in e) return { kind: "failed", at, failure: { kind: e.failed } };
  return { kind: "unreachable", at, detail: e.unreachable };
};

const backlog = {
  events: 0,
  bytes: 0,
  batches: 0,
  oldest: null,
  maxBytes: 0,
  refused: 0,
  discardedFiles: 0,
  quarantined: 0,
};

// Each event as batch.v1 carries it, in the fixture's fields.
const wire = (r: Recorded) => {
  const batch: Batch = {
    id: "00000000-0000-4000-8000-000000000000",
    sentAt: at,
    clock: { source: "ntp", lastSyncAt: at },
    backlog,
    readings: r.kind === "reading" ? [r.reading] : [],
    missedReads: r.kind === "missed" ? [r.missed] : [],
  };
  const json = batchJson(batch);
  const [reading] = json.readings;
  if (reading) {
    const { unit_id, register_key, meter_serial, product_code, value } = reading;
    return { reading: { unit_id, register_key, meter_serial, product_code, value } };
  }
  const [missed] = json.missed_reads;
  if (!missed) throw new Error("no event");
  const { unit_id, register_key, meter_serial, reason, exception_code, detail, attempts, raw_words } = missed;
  return { missed: { unit_id, register_key, meter_serial, reason, exception_code, detail, attempts, raw_words } };
};

const readOf = (step: RoundStep) => {
  if (step.action.kind !== "read") return step.action.kind;
  const { unitId, table, address, count, attempt, waitMs, request } = step.action;
  return { read: [unitId, table, address, count], attempt, wait_ms: waitMs, fc: request.bytes[0] };
};

describe("startRound", () => {
  test("a round of no meters is done at once", () => {
    const step = startRound(endpoint, [], policy);
    expect(step.action).toEqual({ kind: "done" });
    expect(step.round.recorded).toEqual([]);
  });

  test("asks first for the first meter's first identity request, at its first attempt and with no wait", () => {
    const step = startRound(endpoint, meters([{ unit_id: 3, profile: "elite_500" }]), policy);
    expect(readOf(step)).toEqual({ read: [3, "holding", 1999, 28], attempt: 1, wait_ms: 0, fc: 3 });
  });
});

describe("nextRead", () => {
  test.each(fixture.cases.map((c) => [c.why, c] as const))("%s", (_, c) => {
    const final = c.steps.reduce(
      (step, s) => {
        expect(readOf(step)).toEqual({ read: s.read, attempt: s.attempt, wait_ms: s.wait_ms, fc: 3 });
        return nextRead(step.round, event(s.event));
      },
      startRound(endpoint, meters(c.meters), policy),
    );
    expect(final.action).toEqual({ kind: "done" });
    expect(final.round.recorded.map(wire)).toEqual(c.events);
  });

  test("an input register is read with function code 04", () => {
    const base = profile("elite_440");
    const [first, ...rest] = base.registers;
    if (!first) throw new Error("no register");
    const input = { ...base, registers: [{ ...first, table: "input" as const }, ...rest] };
    const [identity] = fixture.cases[0]?.steps ?? [];
    if (!identity) throw new Error("no step");
    const step = nextRead(startRound(endpoint, [{ unitId: 1, profile: input }], policy).round, event(identity.event));
    expect(readOf(step)).toEqual({ read: [1, "input", 199, 2], attempt: 1, wait_ms: 0, fc: 4 });
  });

  test("a socket failure is retried like a timeout, and carries its detail when it misses the meter", () => {
    const failed: ReadEvent = { kind: "failed", at, failure: { kind: "socket", detail: "econnreset" } };
    const start = startRound(endpoint, meters([{ unit_id: 1, profile: "elite_440" }]), policy);
    const final = [failed, failed, failed].reduce((step) => nextRead(step.round, failed), start);
    expect(final.action).toEqual({ kind: "done" });
    expect(final.round.recorded.map(wire)[0]).toEqual({
      missed: {
        unit_id: 1,
        register_key: "active_energy_import",
        meter_serial: null,
        reason: "socket",
        exception_code: null,
        detail: "econnreset",
        attempts: 3,
        raw_words: null,
      },
    });
  });

  test("with no retries, a timeout misses the meter at its first attempt", () => {
    const start = startRound(endpoint, meters([{ unit_id: 1, profile: "elite_440" }]), { ...policy, retries: 0 });
    const final = nextRead(start.round, { kind: "failed", at, failure: { kind: "timeout" } });
    expect(final.action).toEqual({ kind: "done" });
    expect(final.round.recorded.map((r) => (r.kind === "missed" ? r.missed.attempts : -1))).toEqual([1, 0]);
  });

  test("throws on a round that is done, and on a reply of another length than asked", () => {
    const done = startRound(endpoint, [], policy);
    expect(() => nextRead(done.round, { kind: "reply", at, words: [] })).toThrow("the round is done");
    const start = startRound(endpoint, meters([{ unit_id: 1, profile: "elite_440" }]), policy);
    expect(() => nextRead(start.round, { kind: "reply", at, words: [1, 2] })).toThrow("a reply of 2 words");
  });
});
