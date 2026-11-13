defmodule Alavi.Buffer.Codec do
  @moduledoc false
  # The on-disk format of a buffer segment, version 1. Pure: binaries in and out.
  #
  #     segment = magic, header frame, record frame*
  #     magic   = "ALAVIBUF", format version (1 byte)
  #     frame   = payload size (u32, big-endian), CRC-32 of payload (u32), payload
  #
  # The header payload is `{id, clock}`; each record payload is the events of
  # one `Alavi.Buffer.record/2` call. Payloads are plain tuples, not structs, so
  # a later release still decodes them.

  alias Alavi.{Clock, MissedRead, Reading, Sink}

  @magic <<"ALAVIBUF", 1>>

  @typedoc "`size` is the length of the longest valid prefix."
  @type parsed :: %{
          id: <<_::128>>,
          clock: Clock.status(),
          records: [[Sink.event(), ...]],
          size: non_neg_integer()
        }

  @spec header(<<_::128>>, Clock.status()) :: binary()
  def header(<<_::128>> = id, clock),
    do: @magic <> frame({id, encode_clock(clock)})

  @spec record([Sink.event(), ...]) :: binary()
  def record([_ | _] = events), do: events |> Enum.map(&encode_event/1) |> frame()

  # contract: test/alavi/buffer_test.exs "start_link/1"
  @spec parse(binary()) :: {:ok, parsed()} | :error
  def parse(<<@magic, rest::binary>> = segment) do
    with {:ok, {id, clock}, rest} <- next_frame(rest) do
      {records, tail} = frames(rest, [])

      {:ok,
       %{
         id: id,
         clock: decode_clock(clock),
         records: Enum.map(records, fn events -> Enum.map(events, &decode_event/1) end),
         size: byte_size(segment) - tail
       }}
    end
  end

  def parse(_binary), do: :error

  @spec uuid(<<_::128>>) :: String.t()
  def uuid(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>),
    do: Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))

  @spec uuid_v4(<<_::128>>) :: <<_::128>>
  def uuid_v4(<<a::48, _::4, b::12, _::2, c::62>>), do: <<a::48, 4::4, b::12, 2::2, c::62>>

  defp frames(binary, acc) do
    case next_frame(binary) do
      {:ok, term, rest} -> frames(rest, [term | acc])
      :error -> {Enum.reverse(acc), byte_size(binary)}
    end
  end

  defp next_frame(<<size::32, crc::32, payload::binary-size(size), rest::binary>>)
       when size > 0 do
    if :erlang.crc32(payload) == crc, do: {:ok, decode_term(payload), rest}, else: :error
  end

  defp next_frame(_binary), do: :error

  # A payload whose CRC matches is ours: a decode failure is a bug, so it raises.
  defp decode_term(payload), do: :erlang.binary_to_term(payload, [:safe])

  defp frame(term) do
    payload = :erlang.term_to_binary(term, [:compressed])
    <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  defp encode_clock(%{source: source, last_sync_at: at}), do: {source, at && iso(at)}

  defp decode_clock({source, at}) when source in [:ntp, :rtc, :unsynced],
    do: %{source: source, last_sync_at: at && datetime(at)}

  defp encode_event(%Reading{} = r) do
    %Decimal{sign: sign, coef: coef, exp: exp} = r.value

    {:reading, r.endpoint.host, r.endpoint.port, r.unit_id, r.meter_serial, r.profile,
     r.register_key, iso(r.timestamp), r.raw_words, {sign, coef, exp}, r.unit}
  end

  defp encode_event(%MissedRead{} = m) do
    {:missed, m.endpoint.host, m.endpoint.port, m.unit_id, m.meter_serial, m.profile,
     m.register_key, iso(m.timestamp), m.reason, m.attempts, m.raw_words}
  end

  defp decode_event(
         {:reading, host, port, unit_id, serial, profile, key, ts, words, {sign, coef, exp}, unit}
       ) do
    %Reading{
      endpoint: %{host: host, port: port},
      unit_id: unit_id,
      meter_serial: serial,
      profile: profile,
      register_key: key,
      timestamp: datetime(ts),
      raw_words: words,
      value: %Decimal{sign: sign, coef: coef, exp: exp},
      unit: unit
    }
  end

  defp decode_event(
         {:missed, host, port, unit_id, serial, profile, key, ts, reason, attempts, words}
       ) do
    %MissedRead{
      endpoint: %{host: host, port: port},
      unit_id: unit_id,
      meter_serial: serial,
      profile: profile,
      register_key: key,
      timestamp: datetime(ts),
      reason: reason,
      attempts: attempts,
      raw_words: words
    }
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp datetime(text) do
    {:ok, dt, 0} = DateTime.from_iso8601(text)
    dt
  end
end
