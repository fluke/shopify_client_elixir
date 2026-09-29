defmodule ShopifyClient.ThrottlingTest do
  use ShopifyClient.Case, async: true

  # Drain the bucket for the client's shop, as if Shopify had just reported it.
  defp drain(client, available \\ 0) do
    Budget.record(
      ShopifyClient.shop(client),
      %ShopifyClient.Cost{
        currently_available: available,
        maximum_available: 1000,
        restore_rate: 50
      }
    )
  end

  describe "the budget, before sending" do
    test "with :wait, sleeps until the points are back, then sends" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))
      client = client(__MODULE__)
      drain(client)

      assert {:ok, _response} = ShopifyClient.query(client, "{ a }", %{}, cost_hint: 100)
      # 100 points at 50/s is about 2s (a few ms have passed since draining).
      assert_received {:slept, ms} when ms in 1_900..2_000
    end

    test "with :fail_fast, returns :throttled without sending anything" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("no request should be sent") end)
      client = client(__MODULE__, throttle: :fail_fast)
      drain(client)

      assert {:error, %Error{reason: :throttled, details: :budget} = error} =
               ShopifyClient.query(client, "{ a }", %{}, cost_hint: 100)

      assert Error.retry_safe?(error)
      refute_received {:slept, _}
    end

    test "with :wait, a wait longer than :max_wait fails instead" do
      client = client(__MODULE__, max_wait: 500)
      drain(client)

      assert {:error, %Error{reason: :throttled, details: :budget}} =
               ShopifyClient.query(client, "{ a }", %{}, cost_hint: 100)

      refute_received {:slept, _}
    end

    test "enough budget sends immediately" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))
      client = client(__MODULE__)
      drain(client, 900)

      assert {:ok, _response} = ShopifyClient.query(client, "{ a }")
      refute_received {:slept, _}
    end

    test "every response updates the shop's budget" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1}, available: 123)))
      client = client(__MODULE__)

      {:ok, _response} = ShopifyClient.query(client, "{ a }")
      assert_in_delta Budget.available(ShopifyClient.shop(client)), 123, 5
    end
  end

  describe "a THROTTLED answer" do
    test "with :wait, waits for the requested cost and retries" do
      Req.Test.expect(__MODULE__, 2, fn conn ->
        if Process.get(:throttled_once) do
          Req.Test.json(conn, Shopify.data(%{"a" => 1}))
        else
          Process.put(:throttled_once, true)
          Req.Test.json(conn, Shopify.throttled(requested: 200, available: 0, restore_rate: 100))
        end
      end)

      assert {:ok, %Response{data: %{"a" => 1}}} =
               ShopifyClient.query(client(__MODULE__), "{ a }")

      assert_received {:slept, ms} when ms in 1_900..2_000
    end

    test "with :fail_fast, returns :throttled at once" do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, Shopify.throttled()))

      assert {:error, %Error{reason: :throttled, cost: %{requested: 50}} = error} =
               ShopifyClient.query(client(__MODULE__), "{ a }", %{}, throttle: :fail_fast)

      assert Error.retry_safe?(error)
      refute_received {:slept, _}
    end

    test "gives up after :max_throttle_retries" do
      Req.Test.expect(__MODULE__, 3, &Req.Test.json(&1, Shopify.throttled(requested: 10)))

      assert {:error, %Error{reason: :throttled}} =
               ShopifyClient.query(client(__MODULE__), "{ a }", %{}, max_throttle_retries: 2)

      assert_received {:slept, _}
      assert_received {:slept, _}
      refute_received {:slept, _}
    end

    test "emits a throttle event with the wait and its cause" do
      handler = "throttle-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:shopify_client, :throttle], &__MODULE__.send_event/4, self())

      client = client(__MODULE__)
      shop = ShopifyClient.shop(client)
      drain(client)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"a" => 1})))

      ShopifyClient.query(client, "{ a }", %{}, cost_hint: 100)
      :telemetry.detach(handler)

      assert_received {:event, [:shopify_client, :throttle], %{wait_ms: _},
                       %{shop: ^shop, cause: :budget}}
    end
  end

  def send_event(event, measurements, metadata, pid),
    do: send(pid, {:event, event, measurements, metadata})
end
