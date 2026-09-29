defmodule ShopifyClient.BulkTest do
  use ShopifyClient.Case, async: true

  alias ShopifyClient.Bulk
  alias ShopifyClient.Bulk.Operation

  @id "gid://shopify/BulkOperation/1"
  @results_url "https://storage.googleapis.com/shopify-tiers/bulk-1.jsonl?signature=abc"

  defp operation(status, extra \\ %{}) do
    Map.merge(
      %{
        "id" => @id,
        "status" => status,
        "type" => "QUERY",
        "objectCount" => "3",
        "rootObjectCount" => "2",
        "fileSize" => "123",
        "url" => nil
      },
      extra
    )
  end

  describe "run_query/3" do
    test "starts the operation with the query and groupObjects, and returns it" do
      Req.Test.stub(__MODULE__, fn conn ->
        request = graphql_request(conn)

        assert request["query"] =~
                 "bulkOperationRunQuery(query: $query, groupObjects: $groupObjects)"

        assert request["variables"] == %{
                 "query" => "{ products { edges { node { id } } } }",
                 "groupObjects" => false
               }

        payload = %{"bulkOperation" => operation("CREATED"), "userErrors" => []}
        Req.Test.json(conn, Shopify.data(%{"bulkOperationRunQuery" => payload}))
      end)

      assert {:ok, %Operation{id: @id, status: :created, object_count: 3, file_size: 123}} =
               Bulk.run_query(client(__MODULE__), "{ products { edges { node { id } } } }")
    end

    test "userErrors (like an operation already running) become an error" do
      Req.Test.stub(__MODULE__, fn conn ->
        errors = [
          %{
            "field" => nil,
            "message" => "A bulk query operation for this app and shop is already in progress",
            "code" => "OPERATION_IN_PROGRESS"
          }
        ]

        Req.Test.json(
          conn,
          Shopify.user_errors("bulkOperationRunQuery", errors, %{"bulkOperation" => nil})
        )
      end)

      assert {:error, %Error{reason: :user_errors, message: "A bulk query" <> _}} =
               Bulk.run_query(client(__MODULE__), "{ shop { id } }")
    end
  end

  describe "await/3" do
    test "polls by id with backoff until the operation completes" do
      statuses = ["CREATED", "RUNNING", "RUNNING", "COMPLETED"]
      {:ok, agent} = Agent.start_link(fn -> statuses end)

      Req.Test.stub(__MODULE__, fn conn ->
        request = graphql_request(conn)
        assert request["query"] =~ "bulkOperation(id: $id)"
        refute request["query"] =~ "currentBulkOperation"
        assert request["variables"] == %{"id" => @id}

        status = Agent.get_and_update(agent, fn [status | rest] -> {status, rest} end)

        Req.Test.json(
          conn,
          Shopify.data(%{"bulkOperation" => operation(status, %{"url" => @results_url})})
        )
      end)

      assert {:ok, %Operation{status: :completed, url: @results_url}} =
               Bulk.await(client(__MODULE__), @id,
                 interval: 100,
                 max_interval: 250,
                 sleep: &send(self(), {:slept, &1})
               )

      assert_received {:slept, 100}
      assert_received {:slept, 200}
      assert_received {:slept, 250}
    end

    test "a failed operation is an error carrying the operation" do
      Req.Test.stub(__MODULE__, fn conn ->
        body =
          Shopify.data(%{"bulkOperation" => operation("FAILED", %{"errorCode" => "TIMEOUT"})})

        Req.Test.json(conn, body)
      end)

      assert {:error,
              %Error{
                reason: :bulk_operation_failed,
                details: %Operation{status: :failed, error_code: "TIMEOUT"}
              }} =
               Bulk.await(client(__MODULE__), %Operation{id: @id})
    end

    test "gives up after :timeout" do
      Req.Test.stub(
        __MODULE__,
        &Req.Test.json(&1, Shopify.data(%{"bulkOperation" => operation("RUNNING")}))
      )

      assert {:error, %Error{reason: :timeout}} =
               Bulk.await(client(__MODULE__), @id,
                 interval: 1,
                 timeout: 1,
                 sleep: &Process.sleep/1
               )
    end

    test "an unknown id is :not_found" do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, Shopify.data(%{"bulkOperation" => nil})))
      assert {:error, %Error{reason: :not_found}} = Bulk.await(client(__MODULE__), @id)
    end
  end

  describe "stream_results/3" do
    test "streams decoded JSON lines, and never sends the access token to storage" do
      jsonl =
        ~s({"id":"gid://shopify/Product/1"}\n{"id":"gid://shopify/ProductVariant/9","__parentId":"gid://shopify/Product/1"}\n{"id":"gid://shopify/Product/2"}\n)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "storage.googleapis.com"
        assert conn.query_string == "signature=abc"
        assert Plug.Conn.get_req_header(conn, "x-shopify-access-token") == []
        Plug.Conn.send_resp(conn, 200, jsonl)
      end)

      operation = %Operation{id: @id, status: :completed, url: @results_url}

      assert [
               %{"id" => "gid://shopify/Product/1"},
               %{"__parentId" => "gid://shopify/Product/1"},
               %{"id" => "gid://shopify/Product/2"}
             ] = client(__MODULE__) |> Bulk.stream_results(operation) |> Enum.to_list()
    end

    test "is lazy: nothing is downloaded until the stream is consumed" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("downloaded too early") end)
      _stream = Bulk.stream_results(client(__MODULE__), %Operation{id: @id, url: @results_url})
    end

    test "an operation without results yields nothing" do
      assert Enum.to_list(Bulk.stream_results(client(__MODULE__), %Operation{id: @id, url: nil})) ==
               []
    end

    test "partial: true reads partial_data_url" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, ~s({"id":"a"}\n)))
      operation = %Operation{id: @id, status: :failed, partial_data_url: @results_url}

      assert [%{"id" => "a"}] =
               client(__MODULE__)
               |> Bulk.stream_results(operation, partial: true)
               |> Enum.to_list()

      assert [] = client(__MODULE__) |> Bulk.stream_results(operation) |> Enum.to_list()
    end

    test "a failed download raises" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 403, "expired"))

      assert_raise Error, ~r/HTTP 403/, fn ->
        client(__MODULE__)
        |> Bulk.stream_results(%Operation{id: @id, url: @results_url})
        |> Enum.to_list()
      end
    end
  end

  test "cancel/3 cancels by id" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert graphql_request(conn)["variables"] == %{"id" => @id}
      payload = %{"bulkOperation" => operation("CANCELING"), "userErrors" => []}
      Req.Test.json(conn, Shopify.data(%{"bulkOperationCancel" => payload}))
    end)

    assert {:ok, %Operation{status: :canceling}} =
             Bulk.cancel(client(__MODULE__), %Operation{id: @id})
  end

  test "webhook_operation_id/1 reads bulk_operations/finish payloads" do
    assert Bulk.webhook_operation_id(%{"admin_graphql_api_id" => @id, "status" => "completed"}) ==
             @id

    assert Bulk.webhook_operation_id(%{}) == nil
  end

  describe "decode_lines/1" do
    test "reassembles lines split across chunks at any point" do
      jsonl = ~s({"id":1,"title":"caf\u00e9"}\n{"id":2}\n{"id":3})

      # Every possible split into three chunks, including empty ones and
      # splits inside a multi-byte character's escape sequence.
      for i <- 0..byte_size(jsonl), j <- i..byte_size(jsonl) do
        chunks = [
          binary_part(jsonl, 0, i),
          binary_part(jsonl, i, j - i),
          binary_part(jsonl, j, byte_size(jsonl) - j)
        ]

        assert Bulk.decode_lines(chunks) |> Enum.map(& &1["id"]) == [1, 2, 3]
      end
    end

    test "ignores blank lines and a trailing newline" do
      assert [%{"a" => 1}, %{"b" => 2}] =
               Bulk.decode_lines(["\n{\"a\":1}\n\n", "{\"b\":2}\n"]) |> Enum.to_list()
    end

    test "splits a line containing a raw multi-byte character mid-character" do
      line = ~s({"t":"caf\xC3\xA9"}\n)
      {left, right} = String.split_at(line, 7)
      <<first::binary-size(byte_size(left) + 1), rest::binary>> = left <> right
      assert [%{"t" => "caf\xC3\xA9"}] = Bulk.decode_lines([first, rest]) |> Enum.to_list()
    end
  end

  test "unknown statuses stay strings (no atoms from response data)" do
    assert %Operation{status: "PAUSED"} = Operation.from_map(%{"id" => @id, "status" => "PAUSED"})
  end
end
