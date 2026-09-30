defmodule ShopifyClient.RequestOptionsTest do
  use ShopifyClient.Case, async: true

  # Captures the options each request is actually sent with.
  defp capture_options(client) do
    test_pid = self()

    ShopifyClient.update_req(client, fn req ->
      Req.Request.append_request_steps(req,
        capture: fn request ->
          send(test_pid, {:options, request.options})
          request
        end
      )
    end)
  end

  describe ":timeout" do
    test "bounds connecting, pool checkout and the response" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))

      client(__MODULE__, timeout: 1_234) |> capture_options() |> ShopifyClient.query("{ a }")

      assert_received {:options, options}
      assert options.receive_timeout == 1_234
      assert options.pool_timeout == 1_234
      assert options.connect_options[:timeout] == 1_234
    end

    test "keeps connect_options the client was built with" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))

      client(__MODULE__,
        timeout: 500,
        req_options: [plug: {Req.Test, __MODULE__}, connect_options: [protocols: [:http1]]]
      )
      |> capture_options()
      |> ShopifyClient.query("{ a }")

      assert_received {:options, options}
      assert options.connect_options[:protocols] == [:http1]
      assert options.connect_options[:timeout] == 500
    end

    test "can be set per call" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))

      client(__MODULE__) |> capture_options() |> ShopifyClient.query("{ a }", %{}, timeout: 50)

      assert_received {:options, %{receive_timeout: 50}}
    end

    test "unset leaves Req's defaults alone" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))

      client(__MODULE__) |> capture_options() |> ShopifyClient.query("{ a }")

      assert_received {:options, options}
      refute Map.has_key?(options, :pool_timeout)
    end
  end

  describe ":reserve" do
    setup do
      client = client(__MODULE__, throttle: :fail_fast)

      Budget.record(ShopifyClient.shop(client), %ShopifyClient.Cost{
        currently_available: 300,
        maximum_available: 1000,
        restore_rate: 50
      })

      %{client: client}
    end

    test "leaves the reserved points untouched", %{client: client} do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("the reserve would be spent") end)

      assert {:error, %Error{reason: :throttled, details: :budget}} =
               ShopifyClient.query(client, "{ a }", %{}, reserve: 500)
    end

    test "sends when the budget covers the cost plus the reserve", %{client: client} do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))
      assert {:ok, _response} = ShopifyClient.query(client, "{ a }", %{}, reserve: 200)
    end

    test "with :wait, waits for the cost plus the reserve" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))
      client = client(__MODULE__)

      Budget.record(ShopifyClient.shop(client), %ShopifyClient.Cost{
        currently_available: 0,
        maximum_available: 1000,
        restore_rate: 50
      })

      assert {:ok, _response} =
               ShopifyClient.query(client, "{ a }", %{}, reserve: 90, cost_hint: 10)

      # 100 points at 50/s is about 2s.
      assert_received {:slept, ms} when ms in 1_900..2_000
    end
  end

  describe ":query_retries" do
    defp fail_once_then(ok_body, failure) do
      Req.Test.expect(__MODULE__, 2, fn conn ->
        if Process.get(:failed_once) do
          Req.Test.json(conn, ok_body)
        else
          Process.put(:failed_once, true)
          failure.(conn)
        end
      end)
    end

    test "retries a query after a transport error, with backoff" do
      fail_once_then(Shopify.data(%{"a" => 1}), &Req.Test.transport_error(&1, :econnrefused))

      assert {:ok, %Response{data: %{"a" => 1}}} =
               ShopifyClient.query(client(__MODULE__), "query A { a }", %{}, query_retries: 2)

      assert_received {:slept, 100}
    end

    test "retries a query after a 5xx" do
      fail_once_then(Shopify.data(%{"a" => 1}), &Plug.Conn.send_resp(&1, 503, "down"))

      assert {:ok, _response} =
               ShopifyClient.query(client(__MODULE__), "{ a }", %{}, query_retries: 1)
    end

    test "never retries a mutation (it may already have run)" do
      Req.Test.expect(__MODULE__, 1, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Error{reason: :transport}} =
               ShopifyClient.query(client(__MODULE__), "mutation M { a }", %{}, query_retries: 3)

      refute_received {:slept, _}
    end

    test "gives up after the configured retries, backing off each time" do
      Req.Test.expect(__MODULE__, 3, &Plug.Conn.send_resp(&1, 502, "bad gateway"))

      assert {:error, %Error{reason: :server_error}} =
               ShopifyClient.query(client(__MODULE__), "{ a }", %{}, query_retries: 2)

      assert_received {:slept, 100}
      assert_received {:slept, 200}
      refute_received {:slept, _}
    end

    test "are off by default" do
      Req.Test.expect(__MODULE__, 1, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{reason: :transport}} =
               ShopifyClient.query(client(__MODULE__), "{ a }")
    end

    test "emit a retry event" do
      handler = "retry-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:shopify_client, :retry], &__MODULE__.send_event/4, self())
      fail_once_then(Shopify.data(%{"a" => 1}), &Req.Test.transport_error(&1, :closed))

      ShopifyClient.query(client(__MODULE__), "{ a }", %{}, query_retries: 1)
      :telemetry.detach(handler)

      assert_received {:event, [:shopify_client, :retry], %{delay_ms: 100}, %{reason: :transport}}
    end
  end

  test "query_operation?/1 tells queries from mutations" do
    assert ShopifyClient.query_operation?("{ shop { id } }")
    assert ShopifyClient.query_operation?("query Q { shop { id } }")
    assert ShopifyClient.query_operation?("  # a comment\nquery Q { a }")
    refute ShopifyClient.query_operation?("mutation M { a }")
    refute ShopifyClient.query_operation?("# fetches nothing\n  mutation M { a }")
    refute ShopifyClient.query_operation?("subscription S { a }")
    # A field or argument merely named "mutation" doesn't make it one.
    assert ShopifyClient.query_operation?("{ mutationLog { id } }")
  end

  def send_event(event, measurements, metadata, pid),
    do: send(pid, {:event, event, measurements, metadata})
end
