defmodule Alavi.Modbus.Selector do
  @moduledoc """
  The one Modbus write this system makes, and the only code that can build
  one: a single selector register, which chooses the stored billing history,
  daily snapshot or load-survey day and parameter a meter shows. Only the
  addresses in `allowlist/0`, each with its model's function code (06 on the
  Elite 440 family, 16 on the Elite 500), and only a value in range for the
  meter. Every other request is a read, built by `Alavi.Modbus.PDU`.

  A value's range depends on the meter, so the caller passes `bound`, read
  from the meter beforehand:

  - `:through_available`: 0 to the count of stored entries (0 is live values);
  - `:one_through_available`: 1 to that count: the Elite 440's history shows
    0 (live values) until written, and refuses a write of 0 (exception 03,
    every 440 tried, 2026-11-22);
  - `:below_available`: 0 to that count less one (0 is today);
  - `:supported_bit`: a parameter number whose bit is set in the meter's
    supported-parameter mask.

  Each entry also has a `max`, the largest value its register holds, whatever
  the meter counts; `reachable/3` says how many entries that leaves.
  """

  import Bitwise

  @enforce_keys [:function_code, :address, :value, :settle_ms]
  defstruct @enforce_keys

  @typedoc "A selector write request, built only by `request/4`."
  @opaque t :: %__MODULE__{
            function_code: function_code(),
            address: 0..0xFFFF,
            value: 0..0xFFFF,
            settle_ms: non_neg_integer()
          }

  @typedoc "A profile name, as in `contract/profiles/`."
  @type model :: String.t()
  @type name :: :history | :snapshot | :load_survey_day | :load_survey_parameter
  @type function_code :: 6 | 16
  @type range :: :through_available | :one_through_available | :below_available | :supported_bit
  @type entry :: %{
          model: model(),
          name: name(),
          address: 0..0xFFFF,
          function_code: function_code(),
          range: range(),
          max: 0..0xFFFF,
          settle_ms: non_neg_integer(),
          source: String.t()
        }
  @type reply_error :: {:exception, 1..255} | :echo_mismatch

  # PDU address = register number − 40001. `settle_ms`: the 500 needs 100 ms
  # after a load-survey selector write before the entry is read. `max`: the
  # 500's day register keeps only its low byte and selects by it, so 256 shows
  # day 0 (measured on a 500, 2026-11-18), though `DLSuppDays` reads 335-735.
  @allowlist [
    %{
      model: "elite_440",
      name: :history,
      address: 520,
      function_code: 6,
      range: :one_through_available,
      max: 0xFFFF,
      settle_ms: 0,
      source: "elite_440-a"
    },
    %{
      model: "elite_440",
      name: :snapshot,
      address: 700,
      function_code: 6,
      range: :below_available,
      max: 0xFFFF,
      settle_ms: 0,
      source: "elite_440-a"
    },
    %{
      model: "elite_440",
      name: :load_survey_parameter,
      address: 800,
      function_code: 6,
      range: :supported_bit,
      max: 0xFFFF,
      settle_ms: 0,
      source: "elite_440-a"
    },
    %{
      model: "elite_440",
      name: :load_survey_day,
      address: 801,
      function_code: 6,
      range: :below_available,
      max: 0xFFFF,
      settle_ms: 0,
      source: "elite_440-a"
    },
    %{
      model: "elite_500",
      name: :history,
      address: 900,
      function_code: 16,
      range: :through_available,
      max: 0xFFFF,
      settle_ms: 0,
      source: "elite_500-a"
    },
    %{
      model: "elite_500",
      name: :snapshot,
      address: 1500,
      function_code: 16,
      range: :below_available,
      max: 0xFFFF,
      settle_ms: 0,
      source: "elite_500-a"
    },
    %{
      model: "elite_500",
      name: :load_survey_day,
      address: 5002,
      function_code: 16,
      range: :below_available,
      max: 0xFF,
      settle_ms: 100,
      source: "elite_500-a"
    },
    %{
      model: "elite_500",
      name: :load_survey_parameter,
      address: 5003,
      function_code: 16,
      range: :supported_bit,
      max: 0xFFFF,
      settle_ms: 100,
      source: "elite_500-a"
    }
  ]

  # contract: test/alavi/modbus/selector_test.exs "allowlist/0"
  @spec allowlist() :: [entry()]
  def allowlist, do: @allowlist

  # contract: test/alavi/modbus/selector_test.exs "request/4"
  @spec request(model(), name(), integer(), integer()) ::
          {:ok, t()} | {:error, :not_allowed | :out_of_range}
  def request(model, name, value, bound) do
    case entry(model, name) do
      nil -> {:error, :not_allowed}
      entry -> build(entry, value, bound)
    end
  end

  # contract: test/alavi/modbus/selector_test.exs "reachable/3"
  @doc """
  How many of the `count` entries a meter reports `name` can select: all of
  them, unless the register's `max` stops short.
  """
  @spec reachable(model(), name(), non_neg_integer()) :: non_neg_integer()
  def reachable(model, name, count) do
    case entry(model, name) do
      %{range: :below_available, max: max} ->
        min(count, max + 1)

      %{range: range, max: max} when range in [:through_available, :one_through_available] ->
        min(count, max)
    end
  end

  # contract: test/alavi/modbus/selector_test.exs "put_back/4"
  @doc """
  The value a session puts back for a selector it found at `value`: that
  value, or, for one the meter shows but refuses as a write (an Elite 440's
  history at 0), the lowest it accepts.
  """
  @spec put_back(model(), name(), integer(), integer()) ::
          {:ok, integer()} | {:error, :not_allowed | :out_of_range}
  def put_back(model, name, value, bound) do
    case {request(model, name, value, bound), entry(model, name)} do
      {{:ok, _request}, _entry} -> {:ok, value}
      {{:error, :out_of_range}, %{range: :one_through_available}} when value == 0 -> lowest(bound)
      {{:error, reason}, _entry} -> {:error, reason}
    end
  end

  defp lowest(bound) when bound >= 1, do: {:ok, 1}
  defp lowest(_bound), do: {:error, :out_of_range}

  defp entry(model, name), do: Enum.find(@allowlist, &(&1.model == model and &1.name == name))

  defp build(entry, value, bound) when is_integer(value) and is_integer(bound) do
    if value in 0..entry.max and in_range?(entry.range, value, bound) do
      {:ok,
       %__MODULE__{
         function_code: entry.function_code,
         address: entry.address,
         value: value,
         settle_ms: entry.settle_ms
       }}
    else
      {:error, :out_of_range}
    end
  end

  defp build(_entry, _value, _bound), do: {:error, :out_of_range}

  defp in_range?(:through_available, value, available), do: value <= available
  defp in_range?(:one_through_available, value, available), do: value in 1..available//1
  defp in_range?(:below_available, value, available), do: value < available
  defp in_range?(:supported_bit, value, mask), do: mask >= 0 and (mask >>> value &&& 1) == 1

  @spec bytes(t()) :: binary()
  def bytes(%__MODULE__{function_code: 6, address: address, value: value}),
    do: <<6, address::16, value::16>>

  def bytes(%__MODULE__{function_code: 16, address: address, value: value}),
    do: <<16, address::16, 1::16, 2, value::16>>

  @spec function_code(t()) :: function_code()
  def function_code(%__MODULE__{function_code: function_code}), do: function_code

  @doc "How long to wait after a write's echo before reading the entry it selected, in ms."
  @spec settle_ms(t()) :: non_neg_integer()
  def settle_ms(%__MODULE__{settle_ms: settle_ms}), do: settle_ms

  # contract: test/alavi/modbus/selector_test.exs "parse_reply/2"
  @spec parse_reply(t(), binary()) :: :ok | {:error, reply_error()}
  def parse_reply(%__MODULE__{function_code: fc} = request, reply) do
    exception_fc = fc + 0x80

    case reply do
      <<^exception_fc, code>> when code > 0 -> {:error, {:exception, code}}
      reply -> if reply == echo(request), do: :ok, else: {:error, :echo_mismatch}
    end
  end

  defp echo(%__MODULE__{function_code: 6} = request), do: bytes(request)

  defp echo(%__MODULE__{function_code: 16, address: address}),
    do: <<16, address::16, 1::16>>
end
