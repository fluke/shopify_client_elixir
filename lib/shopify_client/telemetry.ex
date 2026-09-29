defmodule ShopifyClient.Telemetry do
  @moduledoc """
  `:telemetry` events emitted by `ShopifyClient`.

    * `[:shopify_client, :query, :start]` / `[:shopify_client, :query, :stop]` /
      `[:shopify_client, :query, :exception]` - one span per `ShopifyClient.query/4`
      call, including any waits and throttle retries.
      * Metadata: `:shop`, `:api_version`, `:operation` (the operation name,
        when the query has one). `:stop` adds `:result` (`:ok` or
        `{:error, reason}`) and `:cost` (a `ShopifyClient.Cost`, or `nil`).
      * Measurements: `:duration` (on `:stop`), in native time units.

    * `[:shopify_client, :throttle]` - the client is about to wait for budget.
      * Measurements: `:wait_ms`.
      * Metadata: `:shop`, `:cause` (`:budget` when the local budget was
        short before sending, `:throttled` when Shopify answered `THROTTLED`).

    * `[:shopify_client, :deprecated]` - Shopify flagged the request as using
      a deprecated API (the `X-Shopify-API-Deprecated-Reason` header).
      * Metadata: `:shop`, `:reason`.
  """
end
