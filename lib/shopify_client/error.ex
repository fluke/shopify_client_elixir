defmodule ShopifyClient.Error do
  @moduledoc """
  Every failure `ShopifyClient` returns, normalized to one exception.

  `:reason` is one of:

    * `:throttled` - Shopify reported `THROTTLED`, or the local per-shop budget
      would have been exceeded (`details: :budget`). Always safe to retry: the
      query did not run.
    * `:access_denied` - a missing access scope (`ACCESS_DENIED`).
    * `:max_cost_exceeded` - the query is too expensive to ever run.
    * `:graphql` - any other top-level GraphQL error (see `:errors`).
    * `:user_errors` - a mutation's `userErrors` were not empty (see `:errors`).
    * `:unauthorized` (401), `:payment_required` (402), `:forbidden` (403),
      `:not_found` (404), `:locked` (423) - the shop or token can't be used;
      usually uninstalled, frozen, or closed. See `shop_unavailable?/1`.
    * `:server_error` - a 5xx from Shopify. The query may or may not have run.
    * `:http` - any other unexpected HTTP status.
    * `:transport` - the request never got a response (see `:details`). The
      query may or may not have run.
    * `:bulk_operation_failed` - a bulk operation ended failed, canceled or
      expired (the `ShopifyClient.Bulk.Operation` is in `:details`).
    * `:timeout` - `ShopifyClient.Bulk.await/3` gave up waiting.
  """

  @type reason ::
          :throttled
          | :access_denied
          | :max_cost_exceeded
          | :graphql
          | :user_errors
          | :unauthorized
          | :payment_required
          | :forbidden
          | :not_found
          | :locked
          | :server_error
          | :http
          | :transport
          | :bulk_operation_failed
          | :timeout

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          errors: [map()],
          status: non_neg_integer() | nil,
          cost: ShopifyClient.Cost.t() | nil,
          details: term(),
          response: ShopifyClient.Response.t() | nil
        }

  defexception [:reason, :message, :status, :cost, :details, :response, errors: []]

  @shop_unavailable [:unauthorized, :payment_required, :forbidden, :not_found, :locked]

  @doc "True when the shop or its token can't be used (401/402/403/404/423)."
  @spec shop_unavailable?(t()) :: boolean()
  def shop_unavailable?(%__MODULE__{reason: reason}), do: reason in @shop_unavailable

  @doc """
  True when retrying can't cause a duplicate write: Shopify did not run the
  operation (it was throttled, locally or by Shopify).
  """
  @spec retry_safe?(t()) :: boolean()
  def retry_safe?(%__MODULE__{reason: :throttled}), do: true
  def retry_safe?(%__MODULE__{}), do: false

  @impl true
  def message(%__MODULE__{message: message}) when is_binary(message), do: message
  def message(%__MODULE__{reason: reason}), do: "Shopify request failed: #{reason}"
end
