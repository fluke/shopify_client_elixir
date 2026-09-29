defmodule ShopifyClient.Budget do
  @moduledoc """
  A per-shop estimate of Shopify's GraphQL cost bucket, shared by every
  process in the node.

  Each response's `throttleStatus` is recorded here. Between responses the
  bucket is assumed to refill at `restoreRate` points per second, up to
  `maximumAvailable`. `ShopifyClient.query/4` consults it *before* sending,
  so a busy app waits (or fails fast) instead of spending a request just to
  be told `THROTTLED`.

  It is an estimate: other apps and processes on other nodes spend the same
  bucket. It errs toward sending; Shopify's own `THROTTLED` response is
  still handled.

  The table is an ETS table owned by this process (started by the
  `:shopify_client` application); reads and writes go straight to ETS, never
  through the process.
  """
  use GenServer

  alias ShopifyClient.Cost

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records the throttle status Shopify reported for `shop`."
  @spec record(String.t(), Cost.t() | nil, integer()) :: :ok
  def record(shop, cost, now_ms \\ now_ms()) do
    if Cost.throttle_known?(cost) do
      entry = {shop, cost.currently_available, cost.maximum_available, cost.restore_rate, now_ms}
      :ets.insert(@table, entry)
    end

    :ok
  end

  @doc "The estimated points available for `shop` now, or `nil` if never seen."
  @spec available(String.t(), integer()) :: float() | nil
  def available(shop, now_ms \\ now_ms()) do
    case :ets.lookup(@table, shop) do
      [{^shop, available, maximum, rate, at_ms}] ->
        min(maximum, available + rate * max(now_ms - at_ms, 0) / 1000)

      [] ->
        nil
    end
  end

  @doc """
  Milliseconds until `points` are estimated to be available for `shop`: `0`
  when they already are, or when nothing is known about the shop yet. A
  request costing more than the whole bucket waits for a full bucket.
  """
  @spec wait_ms(String.t(), number(), integer()) :: non_neg_integer()
  def wait_ms(shop, points, now_ms \\ now_ms()) do
    case :ets.lookup(@table, shop) do
      [{^shop, _available, maximum, rate, _at_ms}] ->
        needed = min(points, maximum)
        shortfall = needed - available(shop, now_ms)
        if shortfall > 0, do: ceil(shortfall / rate * 1000), else: 0

      [] ->
        0
    end
  end

  @doc "Forgets everything recorded for `shop`."
  @spec forget(String.t()) :: :ok
  def forget(shop) do
    :ets.delete(@table, shop)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
