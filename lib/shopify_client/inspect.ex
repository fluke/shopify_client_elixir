defimpl Inspect, for: ShopifyClient do
  # Only what identifies the client. Never the token or the Req internals,
  # however the client ends up in a log line or crash report.
  def inspect(%ShopifyClient{shop: shop, api_version: api_version}, _opts) do
    "#ShopifyClient<#{shop} #{api_version}>"
  end
end
