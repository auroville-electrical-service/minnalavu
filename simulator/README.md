# simulator

A Modbus endpoint that serves Elite register maps (`contract/profiles/`) on
daisy-chained unit ids, over Modbus TCP or RTU over TCP, with injectable faults:
silent meters, busy endpoint, bad CRC, slow responses, word-order variants and a
connection limit.

```sh
bin/dev simulator mix simulator.run --port 5020 --framing tcp --meter 1:elite_440 --meter 3:elite_500
```

In tests: `start_supervised!({Simulator, framing: :tcp, meters: [...]})`; see
`Simulator` and `Simulator.Faults`.
