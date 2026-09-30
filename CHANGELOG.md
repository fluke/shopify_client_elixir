# Changelog

## 0.2.0 (2026-09-30)

- `:timeout`: one deadline for every stage of a request (connect, pool checkout, response), per client or per call. It's merged into existing `connect_options`, and doesn't apply to bulk-result downloads.
- `:reserve`: points to leave in a shop's bucket for others sharing its API budget. A request is only sent (or waited for) when the budget covers `:cost_hint` plus the reserve.
- `:query_retries`: opt-in retries for queries after a transport error or 5xx, with backoff (100ms, doubling, at most 2s), plus a `[:shopify_client, :retry]` event. Mutations are never retried.
- Fix: a non-JSON error body (such as a 502's HTML) no longer turns into a `:transport` error that loses the HTTP status. Responses are decoded by the client, not Req.

## 0.1.0 (2026-09-30)

First version, released on GitHub (not yet on Hex).

- `ShopifyClient.new/1`: an opaque client for the Shopify GraphQL Admin API. HTTP (Req) is an implementation detail, customizable through `:req_options` and `update_req/2`. The API version is required, requests only go to `*.myshopify.com`, and `inspect/1` shows only the shop and API version, never the token.
- `ShopifyClient.query/4` and `query!/4`: responses carry the parsed cost, and every failure is normalized into `ShopifyClient.Error`, including mutation `userErrors`.
- A per-shop cost budget (`ShopifyClient.Budget`), checked before each request, with a `:wait` or `:fail_fast` throttle policy.
- `ShopifyClient.stream/4`: cursor pagination as a lazy `Stream`.
- `ShopifyClient.Bulk`: bulk queries tracked by id, polling with backoff, webhook support, and results streamed as JSON Lines.
- Telemetry events, and `ShopifyClient.Test` body builders for use with `Req.Test`.
