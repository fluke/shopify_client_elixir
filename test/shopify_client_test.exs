defmodule ShopifyClientTest do
  use ShopifyClient.Case, async: true

  import ExUnit.CaptureLog

  describe "new/1" do
    test "posts to the shop's versioned GraphQL endpoint with the token and a user-agent" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.host =~ ~r/\Ashop-\d+\.myshopify\.com\z/
        assert conn.request_path == "/admin/api/2026-04/graphql.json"
        assert Plug.Conn.get_req_header(conn, "x-shopify-access-token") == ["shpat_secret_token"]
        assert [agent] = Plug.Conn.get_req_header(conn, "user-agent")
        assert agent =~ "MyApp shopify_client/"

        assert graphql_request(conn) == %{
                 "query" => "query Shop { shop { name } }",
                 "variables" => %{"x" => 1}
               }

        Req.Test.json(conn, Shopify.data(%{"shop" => %{"name" => "Example"}}))
      end)

      client = client(__MODULE__, app_name: "MyApp")

      assert {:ok, %Response{data: %{"shop" => %{"name" => "Example"}}}} =
               ShopifyClient.query(client, "query Shop { shop { name } }", %{"x" => 1})
    end

    test "the access token never appears in inspect/1" do
      inspected = inspect(client(__MODULE__))
      refute inspected =~ "shpat_secret_token"
    end

    test "normalizes the shop domain" do
      for input <- ["example", "Example.myshopify.com", "https://example.myshopify.com/"] do
        assert ShopifyClient.normalize_shop!(input) == "example.myshopify.com"
      end
    end

    test "refuses hosts other than myshopify.com (the token is sent there)" do
      for input <- ["example.com", "evil.example.com/x", "", "exa mple"] do
        assert_raise ArgumentError, fn -> ShopifyClient.normalize_shop!(input) end
      end
    end

    test "requires a well-formed API version, with no default" do
      assert_raise ArgumentError, ~r/API version/, fn ->
        ShopifyClient.new(shop: "example", access_token: "t", api_version: "latest")
      end

      assert_raise NimbleOptions.ValidationError, ~r/api_version/, fn ->
        ShopifyClient.new(shop: "example", access_token: "t")
      end
    end

    test "inspect/1 shows only the shop and API version" do
      client = client(__MODULE__, shop: "example")
      assert inspect(client) == "#ShopifyClient<example.myshopify.com 2026-04>"
    end

    test "exposes the shop and API version" do
      client = client(__MODULE__, shop: "example", api_version: "unstable")
      assert ShopifyClient.shop(client) == "example.myshopify.com"
      assert ShopifyClient.api_version(client) == "unstable"
    end

    test ":req_options reach the HTTP layer" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-extra") == ["yes"]
        Req.Test.json(conn, Shopify.data(%{"a" => 1}))
      end)

      client =
        client(__MODULE__,
          req_options: [plug: {Req.Test, __MODULE__}, headers: [{"x-extra", "yes"}]]
        )

      assert {:ok, _response} = ShopifyClient.query(client, "{ a }")
    end

    test "update_req/2 steps run on every request" do
      test_pid = self()
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))

      client =
        client(__MODULE__)
        |> ShopifyClient.update_req(fn req ->
          Req.Request.append_request_steps(req,
            trace: fn request ->
              send(test_pid, :traced)
              request
            end
          )
        end)

      ShopifyClient.query(client, "{ a }")
      assert_received :traced
    end

    test "update_req/2 must return a Req request" do
      assert_raise ArgumentError, ~r/expects a Req.Request back/, fn ->
        ShopifyClient.update_req(client(__MODULE__), fn _req -> :oops end)
      end
    end

    test "query/4 with something other than a client explains itself" do
      assert_raise ArgumentError, ~r/expected a client from ShopifyClient.new\/1/, fn ->
        ShopifyClient.query(Req.new(), "{ shop { name } }")
      end
    end
  end

  describe "successful responses" do
    test "carry data, extensions and the parsed cost" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, Shopify.data(%{"a" => 1}, cost: 12, available: 1500))
      end)

      assert {:ok, %Response{} = response} = ShopifyClient.query(client(__MODULE__), "{ a }")
      assert response.cost.actual == 12
      assert response.cost.currently_available == 1500
      assert response.cost.restore_rate == 100
      assert response.extensions["cost"]["requestedQueryCost"] == 12
    end

    test "query!/4 returns the response or raises the error" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))
      assert %Response{data: %{"a" => 1}} = ShopifyClient.query!(client(__MODULE__), "{ a }")

      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.errors("Field 'b' doesn't exist")))

      assert_raise Error, ~r/Field 'b' doesn't exist/, fn ->
        ShopifyClient.query!(client(__MODULE__), "{ b }")
      end
    end
  end

  describe "GraphQL errors" do
    for {code, reason} <- [
          {"ACCESS_DENIED", :access_denied},
          {"MAX_COST_EXCEEDED", :max_cost_exceeded},
          {nil, :graphql}
        ] do
      test "#{inspect(code)} becomes #{inspect(reason)}" do
        Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.errors("nope", unquote(code))))

        assert {:error, %Error{reason: unquote(reason), message: "nope", errors: [_]}} =
                 ShopifyClient.query(client(__MODULE__), "{ a }")
      end
    end
  end

  describe "userErrors" do
    setup do
      Req.Test.stub(__MODULE__, fn conn ->
        body =
          Shopify.user_errors(
            "metafieldsSet",
            [%{"field" => ["key"], "message" => "is invalid"}],
            %{"metafields" => []}
          )

        Req.Test.json(conn, body)
      end)

      :ok
    end

    test "fail the call by default" do
      assert {:error, %Error{reason: :user_errors} = error} =
               ShopifyClient.query(client(__MODULE__), "mutation { metafieldsSet }")

      assert error.message == "is invalid"
      assert [%{"field" => ["key"]}] = error.errors
      assert error.response.data["metafieldsSet"]["metafields"] == []
    end

    test "are left in the data with user_errors: :ignore" do
      assert {:ok, %Response{data: data}} =
               ShopifyClient.query(client(__MODULE__), "mutation { metafieldsSet }", %{},
                 user_errors: :ignore
               )

      assert [%{"message" => "is invalid"}] = data["metafieldsSet"]["userErrors"]
    end

    test "an empty userErrors list is success" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.user_errors("metafieldsSet", [])))

      assert {:ok, _response} =
               ShopifyClient.query(client(__MODULE__), "mutation { metafieldsSet }")
    end
  end

  describe "HTTP and transport failures" do
    for {status, reason} <- [
          {401, :unauthorized},
          {402, :payment_required},
          {403, :forbidden},
          {404, :not_found},
          {423, :locked},
          {500, :server_error},
          {503, :server_error},
          {418, :http}
        ] do
      test "HTTP #{status} becomes #{inspect(reason)}" do
        Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, unquote(status), "{}"))

        assert {:error, %Error{reason: unquote(reason), status: unquote(status)} = error} =
                 ShopifyClient.query(client(__MODULE__), "{ a }")

        assert Error.shop_unavailable?(error) == unquote(status) in [401, 402, 403, 404, 423]
      end
    end

    test "a transport error is reported, not retried" do
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{reason: :transport, details: :econnrefused}} =
               ShopifyClient.query(client(__MODULE__), "mutation { a }")
    end

    test "a non-JSON 200 is an :http error" do
      Req.Test.stub(__MODULE__, &Req.Test.html(&1, "<html>maintenance</html>"))

      assert {:error, %Error{reason: :http, status: 200}} =
               ShopifyClient.query(client(__MODULE__), "{ a }")
    end
  end

  describe "deprecation warnings" do
    test "are logged once per reason, and emitted as telemetry every time" do
      reason = "deprecated-#{System.unique_integer([:positive])}"
      handler = "handler-#{reason}"
      :telemetry.attach(handler, [:shopify_client, :deprecated], &__MODULE__.send_event/4, self())

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-shopify-api-deprecated-reason", reason)
        |> Req.Test.json(Shopify.data(%{"a" => 1}))
      end)

      client = client(__MODULE__)

      log =
        capture_log(fn ->
          ShopifyClient.query(client, "{ a }")
          ShopifyClient.query(client, "{ a }")
        end)

      :telemetry.detach(handler)

      assert length(String.split(log, reason)) == 2
      assert_received {:event, [:shopify_client, :deprecated], %{}, %{reason: ^reason}}
      assert_received {:event, [:shopify_client, :deprecated], %{}, %{reason: ^reason}}
    end
  end

  describe "telemetry" do
    test "a span per query with the operation name, result and cost" do
      handler = "span-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:shopify_client, :query, :start], [:shopify_client, :query, :stop]],
        &__MODULE__.send_event/4,
        self()
      )

      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1}, cost: 7)))
      ShopifyClient.query(client(__MODULE__), "query ProductTitles { a }")
      :telemetry.detach(handler)

      assert_received {:event, [:shopify_client, :query, :start], _,
                       %{operation: "ProductTitles"}}

      assert_received {:event, [:shopify_client, :query, :stop], %{duration: _},
                       %{operation: "ProductTitles", result: :ok, cost: %{actual: 7}}}
    end
  end

  test "operation_name/1 reads named operations only" do
    assert ShopifyClient.operation_name("query Products($c: String) { a }") == "Products"
    assert ShopifyClient.operation_name("  mutation SetMetafields { a }") == "SetMetafields"
    assert ShopifyClient.operation_name("{ a }") == nil
  end

  def send_event(event, measurements, metadata, pid),
    do: send(pid, {:event, event, measurements, metadata})
end
