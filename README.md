# ShopifyClient

A client for Shopify's **GraphQL Admin API**, for Elixir. It's built on
[Req](https://hexdocs.pm/req), so everything Req does (adapters, `Req.Test`,
telemetry) still applies.

GraphQL-only, by design: Shopify's REST Admin API is legacy. There's no
OAuth, sessions or webhook plumbing either. This library talks to the API,
and your app owns everything else.

What it does, beyond sending a query:

- **Throttling that doesn't block needlessly.** Every response's
  `throttleStatus` feeds a node-wide, per-shop cost budget, checked *before*
  each request. Choose, per call, whether to wait for budget or fail fast.
- **Errors you can act on.** `THROTTLED`, `ACCESS_DENIED`, mutation
  `userErrors`, shops that are uninstalled or frozen, and transport failures
  all become one `ShopifyClient.Error` with a `:reason`.
- **Pagination as a lazy `Stream`.** Pages are fetched only as they're consumed.
- **Bulk operations the current way.** Tracked by id (not the deprecated
  `currentBulkOperation`), with results streamed line by line, never loaded
  into memory.
- **Safe by default.** The access token never shows up in `inspect/1`, is
  only ever sent to `*.myshopify.com`, and is never sent to bulk-result
  storage. Throttled requests are retried; a mutation that may have run is not.

> Status: pre-release (0.1). Not published to Hex yet.

## Installation

```elixir
def deps do
  [
    {:shopify_client, github: "fluke/shopify_client"}
  ]
end
```

## Usage

```elixir
client =
  ShopifyClient.new(
    shop: "example.myshopify.com",
    access_token: token,
    api_version: "2026-04"
  )

{:ok, %ShopifyClient.Response{data: data, cost: cost}} =
  ShopifyClient.query(client, """
  query Product($id: ID!) {
    product(id: $id) { title status }
  }
  """, %{"id" => "gid://shopify/Product/1"})
```

There is deliberately no default API version: pin one, and bump it on
purpose.

### Throttling

```elixir
# Default: wait (at most :max_wait ms at a time) for budget, and retry
# THROTTLED answers up to :max_throttle_retries times.
ShopifyClient.query(client, query, vars)

# Never sleep: return {:error, %ShopifyClient.Error{reason: :throttled}} at
# once. For callers with a better fallback than waiting.
ShopifyClient.query(client, query, vars, throttle: :fail_fast)
```

A throttled request never ran, so `ShopifyClient.Error.retry_safe?/1` is
true for it. Transport errors and 5xx responses are not retried, because the
operation may already have run.

### Errors

```elixir
case ShopifyClient.query(client, mutation, vars) do
  {:ok, response} -> ...
  {:error, %ShopifyClient.Error{reason: :user_errors, errors: errors}} -> ...
  {:error, %ShopifyClient.Error{} = error} ->
    if ShopifyClient.Error.shop_unavailable?(error), do: mark_uninstalled(shop)
end
```

Pass `user_errors: :ignore` to get mutation `userErrors` back in the data
instead.

### Pagination

```elixir
query = """
query Products($cursor: String) {
  products(first: 250, after: $cursor) {
    nodes { id title }
    pageInfo { hasNextPage endCursor }
  }
}
"""

client
|> ShopifyClient.stream(query, %{}, path: ["products"])
|> Stream.filter(&(&1["title"] =~ "Sale"))
|> Enum.take(10)
```

### Bulk operations

```elixir
{:ok, operation} = ShopifyClient.Bulk.run_query(client, "{ products { edges { node { id } } } }")
{:ok, operation} = ShopifyClient.Bulk.await(client, operation)

client
|> ShopifyClient.Bulk.stream_results(operation)
|> Stream.each(&import_product/1)
|> Stream.run()
```

At scale, skip polling: subscribe to the `bulk_operations/finish` webhook,
then use `ShopifyClient.Bulk.webhook_operation_id/1` and `ShopifyClient.Bulk.get/3`.

### Testing

Clients are `Req` requests, so `Req.Test` works as usual.
`ShopifyClient.Test` builds Shopify-shaped bodies:

```elixir
Req.Test.stub(MyApp.Shopify, fn conn ->
  Req.Test.json(conn, ShopifyClient.Test.data(%{"shop" => %{"name" => "Example"}}))
end)

Req.Test.stub(MyApp.Shopify, &Req.Test.json(&1, ShopifyClient.Test.throttled()))
```

### Telemetry

There's a `[:shopify_client, :query]` span per query, plus `[:shopify_client, :throttle]`
and `[:shopify_client, :deprecated]` events. See `ShopifyClient.Telemetry`.

## Related packages

- [`ex_shopify_schema`](https://hex.pm/packages/ex_shopify_schema): typed
  structs for Admin API types, per API version. It pairs well with this
  client for decoding responses.

## License

MIT
