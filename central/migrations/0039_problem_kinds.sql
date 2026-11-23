-- migrate:up

-- One row per kind health.problems can raise: the one place a kind's meaning
-- lives, written for an operator, so that a reader shows these words rather
-- than its own copy. Literal rows, not a table, so the wording changes only
-- by a migration from the repo and no role may write it. level says what a
-- problem's subject names: collector, endpoint, target (an endpoint's unit),
-- meter (a serial), meter_store (a serial and one of its stores) or place
-- (an address as read, with its collector). meaning and action are generic:
-- what is wrong and what to do, never a site's addresses.
-- contract: central/test/lib/problems.sql (every kind a test raises has a
--   row, at its level), central/test/grants.sql
CREATE VIEW health.problem_kinds AS
  SELECT k.kind, k.level, k.meaning, k.action
  FROM (VALUES
    ('collector_silent', 'collector',
     'The collector has not uploaded for longer than expected.',
     'Check that the collector''s computer is on, the collector is running and the site''s '
     || 'internet connection works. It keeps its readings while offline and sends them when '
     || 'it reconnects.'),
    ('backlog_near_capacity', 'collector',
     'The collector''s buffer of readings not yet uploaded is nearly full. Once it is full, '
     || 'new readings are lost.',
     'Restore the collector''s uploads (its internet connection, the store''s address, its '
     || 'token) before the buffer fills.'),
    ('backlog_refused', 'collector',
     'The collector''s buffer was full and it has refused readings since it started: those '
     || 'readings are lost.',
     'Restore its uploads so the buffer drains, and report the loss. The count clears when '
     || 'the collector restarts.'),
    ('backlog_discarded', 'collector',
     'Part of the collector''s buffer could not be read back and was set aside as discarded '
     || 'files: the readings in it have not been uploaded.',
     'Report it to the developers, with the discarded files from the collector''s buffer '
     || 'directory. Do not delete them.'),
    ('backlog_quarantined', 'collector',
     'The store refused batches from the collector, which set them aside in quarantine and '
     || 'will not send them again: their readings have not been stored.',
     'Report it to the developers, with the collector''s log and its quarantine directory. '
     || 'Do not delete them.'),
    ('config_refused', 'collector',
     'The collector refused the configuration the store serves it and keeps polling with the '
     || 'one it had.',
     'Read the reason in the detail and correct the configuration in the registry.'),
    ('clock_unchecked', 'collector',
     'The collector has not checked its clock against a time server recently, so the times '
     || 'of its readings are not confirmed. Reading goes on.',
     'Check that the collector can reach its time server (NTP, UDP port 123) through the '
     || 'site''s network.'),
    ('endpoint_silent', 'endpoint',
     'No meter behind this gateway has been read for several of its intervals.',
     'Check the gateway''s power and network link, then the wiring from it to its meters.'),
    ('endpoint_never_read', 'endpoint',
     'No meter behind this gateway has been read since it came into service.',
     'Check the gateway''s address and port in the registry, its power and network link, and '
     || 'its serial settings.'),
    ('endpoint_closes_connections', 'endpoint',
     'The gateway accepts the collector''s connection and closes it before answering, as a '
     || 'gateway does when another client holds its one connection.',
     'Find what else connects to the gateway. The collector cannot read it while another '
     || 'client holds the connection.'),
    ('endpoint_errors', 'endpoint',
     'Many reads at this gateway fail, though others succeed.',
     'Check the wiring, termination and length of the chain behind the gateway. The detail '
     || 'counts the failed reads by reason.'),
    ('target_silent', 'target',
     'The meter at this address on the chain has not answered for several of its intervals.',
     'Check the meter there: its power, its wiring to the chain and its unit ID.'),
    ('target_never_read', 'target',
     'Nothing has answered at this address on the chain since it came into service.',
     'Check that a meter is installed there, that its unit ID is this one, and that its '
     || 'serial settings match the chain''s.'),
    ('meter_silent', 'meter',
     'The meter''s address answers, but no reading has carried this meter''s serial number for '
     || 'several of its intervals: another meter may answer there now.',
     'Check which meter is installed at the address, and record any replacement in the '
     || 'registry.'),
    ('meter_never_read', 'meter',
     'The meter''s address answers, but no reading has carried this meter''s serial number '
     || 'since it was placed there.',
     'Check which meter is installed at the address, and correct the registry.'),
    ('unregistered_serial', 'meter',
     'Readings carry a serial number the registry does not hold.',
     'Register the meter at the place it is read.'),
    ('misplaced_serial', 'meter',
     'A registered meter is read somewhere other than where the registry places it.',
     'Check where the meter is installed and correct the registry.'),
    ('serial_at_several_places', 'meter',
     'A serial number the registry does not hold is read at more than one place: two meters '
     || 'reporting one serial, one meter reachable two ways, or a meter that moved.',
     'Check the meters at the places in the detail, and register each where it is.'),
    ('firmware_changed', 'meter',
     'The meter reports different software or firmware than it did before.',
     'Confirm the change was meant: an upgrade, or a replaced meter. A meter with new '
     || 'firmware may need its readings checked before they are billed.'),
    ('energy_backwards', 'meter',
     'An energy register read lower than an earlier reading of it. Cumulative energy should '
     || 'never fall.',
     'Check for a reset, a replaced meter or a clock fault before these readings are billed. '
     || 'The detail says whether the collector''s clock was checked at each reading.'),
    ('snapshot_missed', 'meter',
     'A daily snapshot was replaced on the meter before the collector copied it: that day''s '
     || 'snapshot is lost.',
     'Check why the meter was not copied in time: the collector or the chain down, or the '
     || 'meter polled too slowly.'),
    ('meter_clock_step', 'meter',
     'The meter''s clock jumped between two reads.',
     'Check whether someone set the meter''s clock. Entries the meter stored around the step '
     || 'are dated by it.'),
    ('meter_clock_far', 'meter',
     'The meter''s clock is far from those of the other meters on the same collector.',
     'Have the meter''s clock set at the next visit. The entries it stores are dated by it.'),
    ('copy_failing_polled_slowly', 'meter',
     'The entries the meter stores are falling behind or being missed, and it is polled less '
     || 'often than copying them needs.',
     'Shorten the meter''s polling interval in the registry.'),
    ('copy_behind', 'meter_store',
     'The newest entry copied from this store of the meter is older than expected.',
     'Check that the meter is being read and copied. The meter overwrites its oldest entries, '
     || 'and an entry overwritten before it is copied is lost.'),
    ('several_serials_at_place', 'place',
     'Readings at one address carry more than one serial number: a meter replaced, or two '
     || 'meters answering at one address.',
     'Check the meters there. Record a replacement in the registry, and give one of two '
     || 'meters sharing a unit ID a new one.')
  ) AS k (kind, level, meaning, action);

GRANT SELECT ON TABLE health.problem_kinds TO monitor;

-- migrate:down
-- Forward only. Undo with a new migration.
