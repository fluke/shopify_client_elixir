# Changelog

## 0.1.0 (unreleased)

First version.

- `ShopifyClient.new/1` and `attach/2`: a Req-based client for the Shopify GraphQL Admin API. The API version is required, requests only go to `*.myshopify.com`, and the access token is kept out of `inspect/1`.
- `ShopifyClient.query/4` and `query!/4`: responses carry the parsed cost, and every failure is normalized into `ShopifyClient.Error`, including mutation `userErrors`.
- A per-shop cost budget (`ShopifyClient.Budget`), checked before each request, with a `:wait` or `:fail_fast` throttle policy.
- `ShopifyClient.stream/4`: cursor pagination as a lazy `Stream`.
- `ShopifyClient.Bulk`: bulk queries tracked by id, polling with backoff, webhook support, and results streamed as JSON Lines.
- Telemetry events, and `ShopifyClient.Test` body builders for use with `Req.Test`.
