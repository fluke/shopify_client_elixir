defmodule ShopifyClient.Case do
  @moduledoc """
  Tests talk to a `Req.Test` stub named after the test module instead of
  Shopify. Every client gets its own shop (the budget is node-wide), and a
  `sleep` that reports to the test process instead of sleeping.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import ShopifyClient.Case
      alias ShopifyClient.{Budget, Error, Response}
      alias ShopifyClient.Test, as: Shopify
    end
  end

  @doc "A client for a fresh, unique shop, stubbed by `Req.Test` under `stub`."
  def client(stub, opts \\ []) do
    test_pid = self()

    [
      shop: "shop-#{System.unique_integer([:positive])}",
      access_token: "shpat_secret_token",
      api_version: "2026-04",
      req_options: [plug: {Req.Test, stub}],
      sleep: fn ms -> send(test_pid, {:slept, ms}) end
    ]
    |> Keyword.merge(opts)
    |> ShopifyClient.new()
  end

  @doc "Decodes the GraphQL request a stub received."
  def graphql_request(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
