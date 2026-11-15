defmodule Alavi.Sntp do
  @moduledoc """
  An SNTP client's packets (RFC 4330), pure: the 48-byte request, and a reply
  checked and taken apart.

  The request's transmit timestamp is a random nonce, not the collector's
  clock: the server echoes it as the reply's originate timestamp, which is all
  it is used for, and the collector keeps its own send time.

  A server time is an integer of nanoseconds since the Unix epoch, truncated
  from the NTP fraction (2^-32 s), so it is never later than the server said.
  """

  import Bitwise

  @version 4
  @client 3
  @server 4
  # 1900-01-01 to 1970-01-01, in seconds.
  @unix_epoch 2_208_988_800
  @era 1 <<< 32
  @nanos 1_000_000_000

  @type nonce :: <<_::64>>

  @typedoc "Nanoseconds since the Unix epoch."
  @type time :: integer()

  @typedoc "`received` and `sent` are the server's t2 and t3."
  @type answer :: %{
          stratum: 1..15,
          leap: 0..2,
          reference_id: non_neg_integer(),
          received: time(),
          sent: time()
        }

  @typedoc "`invalid`'s text says why, for the log."
  @type refusal :: {:kiss_of_death, non_neg_integer()} | {:invalid, String.t()}

  # contract: test/alavi/sntp_test.exs "request/1"
  @spec request(nonce()) :: <<_::384>>
  def request(<<_::64>> = nonce), do: <<0::2, @version::3, @client::3, 0::312, nonce::binary>>

  # contract: test/alavi/sntp_test.exs "parse/2"
  @spec parse(binary(), nonce()) :: {:ok, answer()} | {:error, refusal()}
  def parse(
        <<leap::2, version::3, mode::3, stratum::8, _poll::8, _precision::8, _delay::32,
          _dispersion::32, reference_id::32, _reference::64, origin::binary-8, received::64,
          sent::64, _extensions::binary>>,
        <<_::64>> = nonce
      ) do
    with :ok <- expect(mode == @server, "mode #{mode}, not #{@server} (server)"),
         :ok <- expect(version == @version, "version #{version}, not #{@version}"),
         :ok <- expect(origin == nonce, "an originate timestamp that is not the request's"),
         :ok <- kiss(stratum, reference_id),
         :ok <- expect(leap != 3, "leap indicator 3: the server is not synchronised"),
         :ok <- expect(stratum <= 15, "stratum #{stratum}: the server is not synchronised"),
         :ok <- expect(sent != 0, "a transmit timestamp of zero") do
      {:ok,
       %{
         stratum: stratum,
         leap: leap,
         reference_id: reference_id,
         received: time(received),
         sent: time(sent)
       }}
    end
  end

  def parse(packet, <<_::64>>) when is_binary(packet),
    do: {:error, {:invalid, "#{byte_size(packet)} bytes, fewer than an NTP header's 48"}}

  # contract: test/alavi/sntp_test.exs "rfc3339/1"
  @doc "A server time as RFC 3339 in UTC, always with nine fraction digits."
  @spec rfc3339(time()) :: String.t()
  def rfc3339(nanoseconds) when is_integer(nanoseconds) do
    seconds = Integer.floor_div(nanoseconds, @nanos)

    fraction =
      nanoseconds |> Integer.mod(@nanos) |> Integer.to_string() |> String.pad_leading(9, "0")

    seconds
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
    |> String.replace_suffix("Z", ".#{fraction}Z")
  end

  defp expect(true, _why), do: :ok
  defp expect(false, why), do: {:error, {:invalid, why}}

  defp kiss(0, code), do: {:error, {:kiss_of_death, code}}
  defp kiss(_stratum, _code), do: :ok

  # RFC 4330 §3: a seconds field with its top bit set is in era 0 (1968 to
  # 2036), one with it clear in era 1 (2036 to 2104).
  defp time(timestamp), do: time(timestamp >>> 32, timestamp &&& 0xFFFF_FFFF)

  defp time(seconds, fraction) do
    era = if seconds >= 1 <<< 31, do: 0, else: @era
    (seconds + era - @unix_epoch) * @nanos + ((fraction * @nanos) >>> 32)
  end
end
