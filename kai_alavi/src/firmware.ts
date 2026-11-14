import type { Table } from "./pdu";
import type { Firmware, FirmwareName, NameEntry } from "./profile";
import { err, ok, type Result } from "./result";
import { bytesOf, printable, trimmed } from "./text";

// Where a meter reports its software and firmware names, and how what comes back is decoded;
// follows `alavi`'s `Alavi.Profile.Firmware`. Informational only: never gates a read or labels a
// reading.

export interface NameRead {
  readonly name: FirmwareName;
  readonly table: Table;
  readonly address: number;
  readonly count: number;
}

export type NameError = "wrong_word_count" | "empty" | "not_printable";

const names = ["software", "firmware_1", "firmware_2", "modbus_version"] as const satisfies readonly FirmwareName[];

// contract: test/firmware.test.ts "firmwareReads"
export const firmwareReads = (firmware: Firmware): readonly NameRead[] =>
  names.map((name) => {
    const { table, address, count } = firmware[name];
    return { name, table, address, count };
  });

const hex = (words: readonly number[]): string =>
  bytesOf(words)
    .map((b) => b.toString(16).toUpperCase().padStart(2, "0"))
    .join("");

// contract: test/firmware.test.ts "decodeName"
// `words` are in register-address order, as read from the meter. A hex entry is each byte as two
// uppercase hex digits, high byte first: the version word 0x0B03 is "0B03".
export const decodeName = (
  entry: Pick<NameEntry, "count" | "type">,
  words: readonly number[],
): Result<string, NameError> => {
  if (words.length !== entry.count) return err("wrong_word_count");
  switch (entry.type) {
    case "hex":
      return ok(hex(words));
    case "ascii": {
      const bytes = trimmed(bytesOf(words));
      if (bytes.length === 0) return err("empty");
      const text = printable(bytes);
      return text === null ? err("not_printable") : ok(text);
    }
    default: {
      const unknown: never = entry.type;
      return unknown;
    }
  }
};
