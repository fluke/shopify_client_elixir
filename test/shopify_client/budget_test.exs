defmodule ShopifyClient.BudgetTest do
  use ExUnit.Case, async: true

  alias ShopifyClient.{Budget, Cost}

  setup do
    %{shop: "budget-#{System.unique_integer([:positive])}.myshopify.com"}
  end

  defp cost(available, maximum \\ 2000, rate \\ 100),
    do: %Cost{currently_available: available, maximum_available: maximum, restore_rate: rate}

  test "an unseen shop is unknown and never waits", %{shop: shop} do
    assert Budget.available(shop) == nil
    assert Budget.wait_ms(shop, 1_000_000) == 0
  end

  test "the bucket refills at the restore rate, capped at the maximum", %{shop: shop} do
    :ok = Budget.record(shop, cost(100), 0)

    assert Budget.available(shop, 0) == 100
    assert Budget.available(shop, 1_000) == 200
    assert Budget.available(shop, 60_000) == 2000
  end

  test "wait_ms is the time until the points are back", %{shop: shop} do
    :ok = Budget.record(shop, cost(100), 0)

    assert Budget.wait_ms(shop, 50, 0) == 0
    # 400 points short at 100/s.
    assert Budget.wait_ms(shop, 500, 0) == 4_000
    assert Budget.wait_ms(shop, 500, 3_000) == 1_000
  end

  test "a request larger than the bucket waits for a full bucket, not forever", %{shop: shop} do
    :ok = Budget.record(shop, cost(0, 1000, 50), 0)
    assert Budget.wait_ms(shop, 5_000, 0) == 20_000
  end

  test "an incomplete throttle status is ignored", %{shop: shop} do
    :ok = Budget.record(shop, %Cost{currently_available: 10}, 0)
    :ok = Budget.record(shop, nil, 0)
    assert Budget.available(shop) == nil
  end

  test "forget/1 drops the shop", %{shop: shop} do
    :ok = Budget.record(shop, cost(0), 0)
    :ok = Budget.forget(shop)
    assert Budget.available(shop) == nil
  end
end
