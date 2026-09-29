defmodule ShopifyClient.Cost do
  @moduledoc """
  A GraphQL response's query cost and the shop's throttle status, from
  `extensions.cost`.

  Shopify rate-limits the Admin GraphQL API per shop with a leaky bucket of
  cost points: each query spends its actual cost, and the bucket refills at
  `restore_rate` points per second up to `maximum_available`.
  """

  @type t :: %__MODULE__{
          requested: number() | nil,
          actual: number() | nil,
          currently_available: number() | nil,
          maximum_available: number() | nil,
          restore_rate: number() | nil
        }

  defstruct [:requested, :actual, :currently_available, :maximum_available, :restore_rate]

  @doc "Parses `extensions.cost` from a response body; `nil` when absent."
  @spec from_body(map() | term()) :: t() | nil
  def from_body(%{"extensions" => %{"cost" => cost}}) when is_map(cost) do
    throttle = cost["throttleStatus"] || %{}

    %__MODULE__{
      requested: cost["requestedQueryCost"],
      actual: cost["actualQueryCost"],
      currently_available: throttle["currentlyAvailable"],
      maximum_available: throttle["maximumAvailable"],
      restore_rate: throttle["restoreRate"]
    }
  end

  def from_body(_body), do: nil

  @doc "Whether the throttle status is complete enough to budget with."
  @spec throttle_known?(t() | nil) :: boolean()
  def throttle_known?(%__MODULE__{currently_available: a, maximum_available: m, restore_rate: r})
      when is_number(a) and is_number(m) and is_number(r) and r > 0,
      do: true

  def throttle_known?(_cost), do: false
end
