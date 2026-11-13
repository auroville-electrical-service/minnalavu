defmodule Alavi.Poller.Policy do
  alias Alavi.Modbus.Client

  @type action :: :retry | {:retry_after, non_neg_integer()} | :skip_meter | :skip_register

  @wait [0x05, 0x06]
  # The gateway has already waited for the meter, so a retry only costs bus time.
  @gateway [0x0A, 0x0B]

  # contract: test/alavi/poller/policy_test.exs "next/2"
  @doc "`attempt` counts from 1."
  @spec next(Client.error(), pos_integer(), %{
          :retries => non_neg_integer(),
          :busy_backoff_ms => non_neg_integer(),
          optional(atom()) => term()
        }) :: action()
  def next({:exception, code}, _attempt, _endpoint) when code in @gateway, do: :skip_meter

  def next({:exception, code}, attempt, %{retries: retries, busy_backoff_ms: ms})
      when code in @wait and attempt <= retries,
      do: {:retry_after, ms}

  def next({:exception, code}, _attempt, _endpoint) when code in @wait, do: :skip_meter
  # Any other exception means this request is wrong for the meter, so a retry cannot help.
  def next({:exception, _code}, _attempt, _endpoint), do: :skip_register
  def next(:invalid_request, _attempt, _endpoint), do: :skip_register
  def next(_transport, attempt, %{retries: retries}) when attempt <= retries, do: :retry
  def next(_transport, _attempt, _endpoint), do: :skip_meter

  # contract: test/alavi/poller/policy_test.exs "backoff/2"
  @spec backoff(pos_integer(), %{min: pos_integer(), max: pos_integer()}) :: pos_integer()
  def backoff(current, %{max: max}), do: min(current * 2, max)
end
