# Judging copy holes

A collector copies each meter's stored entries newer than its own mark, so
entries the store lacks behind that mark stay missing until someone asks
for them (`central/README.md` *Copy fills*). No threshold or
health problem raises them. A session judges them, with this procedure.

`holes.sql` beside this file runs every query below, read only:

    bin/dev central sh -c 'psql "$MINNALAVU_DB_URL" -X -v since=2026-10-01 -f ../skills/minnalavu-ops/holes.sql'

That is the dev store. A deployed store runs the same file as its operator.

## Two things before any request

- **A fill reaches real meters.** The collector copies in its copy window
  by writing selector registers, the one write the hard rules allow. So
  listing is free, but `admin.request_fill` needs the owner's go-ahead. Show
  the plan first: for each collector, the meters, stores, range and expiry.
- **The collector must run fill jobs.** A release without `fill_copies` in
  `alavi/lib` refuses the job, and the request expires with no results.
  Nothing breaks, but nothing is learned. Check the commit the collector
  runs, not `main`.

## 1. List

Choose `since` as the earliest time anything depends on: the open rating
period, or the oldest entry a moved store should hold. Holes older than a
meter's retention come back `gone`. That is still worth a request when the
answer matters, because only a fill result records that a slot is gone.

Section 1 counts holes per meter and store. A slot is a day, or a month for
history, in the meter's own clock. `admin.copy_holes` only looks between a
store's oldest and newest entries. A store with no entries, or one whose
newest entry is old, shows as `copy_behind` in `health.problems`, and it is
not a hole. After a move to an empty store, every copied meter is behind,
and the README's move procedure applies, not this one.

## 2. Set aside what is settled

- **`gone`:** a fill showed the meter no longer holds the slot. It cannot be
  recovered. Report it.
- **`pending_request`:** a fill offered now will copy the slot. Wait for it.
- **Section 2:** a finished fill covered the slot and the meter still sent
  nothing. The meter holds no entry there, and asking again changes
  nothing.

Section 3 is what is left, grouped per meter and store with its first and
last slot.

## 3. Find the cause before filling

A hole with a known cause just needs filling. A hole with no cause is a
finding about the collector or ingest, and it goes to the owner along with
the fill.

- **The store was moved, restored or rebuilt:** the holes start where the
  backup ends.
- **Buffer segments lost (section 4):** an upload whose discard or
  quarantine count rose. Holes in the days that batch covered follow from
  it, and the segment's own cause is a collector question.
- **A meter clock step (section 5):** a clock set back stamps new entries at
  or before the mark, so they are skipped. A fill copies them, but the
  clock is the thing to raise.
- **None of these:** say so, and do not guess one.

## 4. Shape the requests

`admin.request_fill` takes one collector, one range, and the meters and
stores it applies to. How far back the range starts sets the cost: each
named store is scanned back to `from_time` on every named meter, while
`to_time` only bounds what is sent.

- One request per collector, naming only the stores that have holes.
- `from_time` is the earliest open slot among the meters named, and
  `to_time` the latest slot's end. When a few meters have much older holes
  than the rest, give them a request of their own. Otherwise every meter is
  scanned back to the oldest hole.
- `expires_after` must cover the collector's next copy window and its
  uplink. A day or two is enough for a connected site. For an offline one,
  allow until it is expected back.
- `requester => 'operator'`. Nothing about people is stored here.

Then, with the owner's go-ahead:

    SELECT admin.request_fill(collector_id => '…', meters => ARRAY['…'],
      stores => ARRAY['load_survey'], from_time => '…', to_time => '…',
      requester => 'operator', expires_after => '3 days');

## 5. Follow up

After the collector's next copy window and upload, look at section 6:

- **`answered`:** run sections 1 to 3 again. Filled slots are gone from the
  list, slots the meter no longer holds show `gone`, and the rest move to
  section 2.
- **`expired` with no results:** the collector did not run the fill. It may
  lack fill support, have been offline, or missed its window. Find out
  which before asking again.

Record in the repo's state document what was found, each hole's cause, the
request IDs, and what came back.
