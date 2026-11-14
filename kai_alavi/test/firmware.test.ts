import { describe, expect, test } from "bun:test";
import { decodeName, firmwareReads } from "../src/index";
import { loadFirmwareFixture, loadProfiles } from "./contract";

const fixture = loadFirmwareFixture();
const profiles = loadProfiles();

const firmware = (name: string) => {
  const found = profiles.get(name)?.firmware;
  if (!found) throw new Error(`no firmware section in profile ${name}`);
  return found;
};

describe("firmwareReads", () => {
  test.each(Object.entries(fixture.reads))("%s reads what the fixture lists, in order", (name, reads) => {
    const listed = firmwareReads(firmware(name)).map((r) => [r.name, r.table, r.address, r.count]);
    expect<unknown>(listed).toEqual(reads);
  });
});

describe("decodeName", () => {
  test.each(fixture.cases.map((c) => [`${c.profile} ${c.name}: ${c.why}`, c] as const))("%s", (_, c) => {
    const decoded = decodeName(firmware(c.profile)[c.name], c.words);
    expect(decoded.ok ? { value: decoded.value } : { refused: decoded.error }).toEqual(
      "value" in c ? { value: c.value } : { refused: c.refused },
    );
  });
});
