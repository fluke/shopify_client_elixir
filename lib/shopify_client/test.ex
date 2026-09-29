defmodule ShopifyClient.Test do
  @moduledoc """
  Builders for Shopify-shaped response bodies, for testing code that uses
  `ShopifyClient` with `Req.Test` (which needs `:plug` in your test deps).

      # In the code under test, the client gets its adapter from config:
      #   ShopifyClient.new(shop: ..., access_token: ..., api_version: "2026-04",
      #                     req_options: Application.get_env(:my_app, :shopify_req_options, []))
      #
      # config/test.exs:
      #   config :my_app, :shopify_req_options, plug: {Req.Test, MyApp.Shopify}

      test "reads the shop name" do
        Req.Test.stub(MyApp.Shopify, fn conn ->
          Req.Test.json(conn, ShopifyClient.Test.data(%{"shop" => %{"name" => "Example"}}))
        end)

        assert MyApp.shop_name() == "Example"
      end
  """

  @default_throttle [available: 1990, maximum: 2000, restore_rate: 100]

  @doc """
  A successful response body with `data` and a cost extension.

  Options: `:cost` (actual and requested cost, default `10`), `:available`,
  `:maximum`, `:restore_rate` (the throttle status).
  """
  @spec data(map(), keyword()) :: map()
  def data(data, opts \\ []) do
    %{"data" => data, "extensions" => cost_extension(opts)}
  end

  @doc """
  A `THROTTLED` response body. `:requested` is the query's cost (default
  `50`); `:available` defaults to `0`.
  """
  @spec throttled(keyword()) :: map()
  def throttled(opts \\ []) do
    requested = Keyword.get(opts, :requested, 50)
    opts = Keyword.merge([available: 0, cost: requested], opts)

    %{
      "errors" => [%{"message" => "Throttled", "extensions" => %{"code" => "THROTTLED"}}],
      "extensions" => cost_extension(Keyword.put(opts, :actual, nil))
    }
  end

  @doc "A body with top-level GraphQL `errors`; `code` becomes `extensions.code`."
  @spec errors(String.t(), String.t() | nil) :: map()
  def errors(message, code \\ nil) do
    error = %{"message" => message}
    error = if code, do: Map.put(error, "extensions", %{"code" => code}), else: error
    %{"errors" => [error], "extensions" => cost_extension([])}
  end

  @doc """
  A mutation response whose payload at `root` has `userErrors`.

      ShopifyClient.Test.user_errors("metafieldsSet", [%{"field" => ["key"], "message" => "is invalid"}])
  """
  @spec user_errors(String.t(), [map()], map()) :: map()
  def user_errors(root, errors, payload \\ %{}) do
    data(%{root => Map.put(payload, "userErrors", errors)})
  end

  defp cost_extension(opts) do
    throttle = Keyword.merge(@default_throttle, opts)
    cost = Keyword.get(opts, :cost, 10)

    %{
      "cost" => %{
        "requestedQueryCost" => cost,
        "actualQueryCost" => Keyword.get(opts, :actual, cost),
        "throttleStatus" => %{
          "maximumAvailable" => throttle[:maximum],
          "currentlyAvailable" => throttle[:available],
          "restoreRate" => throttle[:restore_rate]
        }
      }
    }
  end
end
