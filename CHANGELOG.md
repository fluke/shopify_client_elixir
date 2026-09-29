# Changelog

## 0.1.0 (2026-09-30)

First version, released on GitHub (not yet on Hex).

- `ShopifyClient.new/1`: an opaque client for the Shopify GraphQL Admin API. HTTP (Req) is an implementation detail, customizable through `:req_options` and `update_req/2`. The API version is required, requests only go to `*.myshopify.com`, and `inspect/1` shows only the shop and API version, never the token.
- `ShopifyClient.query/4` and `query!/4`: responses carry the parsed cost, and every failure is normalized into `ShopifyClient.Error`, including mutation `userErrors`.
- A per-shop cost budget (`ShopifyClient.Budget`), checked before each request, with a `:wait` or `:fail_fast` throttle policy.
- `ShopifyClient.stream/4`: cursor pagination as a lazy `Stream`.
- `ShopifyClient.Bulk`: bulk queries tracked by id, polling with backoff, webhook support, and results streamed as JSON Lines.
- Telemetry events, and `ShopifyClient.Test` body builders for use with `Req.Test`.
