defmodule ShopifyClient.PaginationTest do
  use ShopifyClient.Case, async: true

  @query """
  query Products($cursor: String) {
    products(first: 2, after: $cursor) {
      nodes { id }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  # Three pages: [1, 2] -> [3, 4] -> [5]. Records each requested cursor.
  defp stub_pages(test_pid) do
    pages = %{
      nil => {[1, 2], "c1"},
      "c1" => {[3, 4], "c2"},
      "c2" => {[5], nil}
    }

    Req.Test.stub(__MODULE__, fn conn ->
      cursor = graphql_request(conn)["variables"]["cursor"]
      send(test_pid, {:page_requested, cursor})
      {ids, next} = Map.fetch!(pages, cursor)

      connection = %{
        "nodes" => Enum.map(ids, &%{"id" => &1}),
        "pageInfo" => %{"hasNextPage" => next != nil, "endCursor" => next}
      }

      Req.Test.json(conn, Shopify.data(%{"products" => connection}))
    end)
  end

  test "streams every node across pages, passing each cursor" do
    stub_pages(self())

    ids =
      client(__MODULE__)
      |> ShopifyClient.stream(@query, %{}, path: ["products"])
      |> Enum.map(& &1["id"])

    assert ids == [1, 2, 3, 4, 5]
    assert_received {:page_requested, nil}
    assert_received {:page_requested, "c1"}
    assert_received {:page_requested, "c2"}
  end

  test "is lazy: only fetches the pages it needs" do
    stub_pages(self())

    assert [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}] =
             client(__MODULE__)
             |> ShopifyClient.stream(@query, %{}, path: ["products"])
             |> Enum.take(3)

    assert_received {:page_requested, nil}
    assert_received {:page_requested, "c1"}
    refute_received {:page_requested, "c2"}
  end

  test "reads edges { node } connections too, and keeps the caller's variables" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert graphql_request(conn)["variables"] == %{"query" => "status:active", "after" => nil}

      connection = %{
        "edges" => [%{"node" => %{"id" => "a"}}],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      }

      Req.Test.json(conn, Shopify.data(%{"shop" => %{"products" => connection}}))
    end)

    query =
      "query($query: String, $after: String) { shop { products { pageInfo { hasNextPage } } } }"

    assert [%{"id" => "a"}] =
             client(__MODULE__)
             |> ShopifyClient.stream(query, %{"query" => "status:active"},
               path: ["shop", "products"],
               cursor_variable: "after"
             )
             |> Enum.to_list()
  end

  test "a failed page raises the error" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.errors("boom")))

    assert_raise Error, "boom", fn ->
      client(__MODULE__)
      |> ShopifyClient.stream(@query, %{}, path: ["products"])
      |> Enum.to_list()
    end
  end

  test "a query without pageInfo is rejected up front" do
    assert_raise ArgumentError, ~r/pageInfo/, fn ->
      ShopifyClient.stream(client(__MODULE__), "{ products { nodes { id } } }", %{},
        path: ["products"]
      )
    end
  end
end
