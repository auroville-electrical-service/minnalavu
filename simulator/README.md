# simulator

A Modbus endpoint that serves Elite register maps (`contract/profiles/`) on
daisy-chained unit ids, over Modbus TCP or RTU over TCP, with injectable faults:
silent meters, busy endpoint, bad CRC, slow responses, word-order variants, a
connection limit, dropped connections and refused selector writes. Behind the
selector writes each meter holds billing histories, daily snapshots and
load-survey days, stamped by its own drifting clock (`Simulator.Stores`).

```sh
bin/dev simulator mix simulator.run --port 5020 --framing tcp --meter 1:elite_440 --meter 3:elite_500
bin/dev simulator mix simulator.run --port 5020 --framing tcp --meter 1:elite_440 --days 34 --clock-offset -99 --clock-drift 23
```

In tests: `start_supervised!({Simulator, framing: :tcp, meters: [...]})`; see
`Simulator` and `Simulator.Faults`.
