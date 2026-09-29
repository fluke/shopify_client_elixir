defmodule ShopifyClient.Bulk do
  @moduledoc """
  Bulk operations: run a query over a whole shop asynchronously, then stream
  the results (JSON Lines) without loading them into memory.

      {:ok, operation} =
        ShopifyClient.Bulk.run_query(client, \"""
        { products { edges { node { id title } } } }
        \""")

      {:ok, operation} = ShopifyClient.Bulk.await(client, operation)

      client
      |> ShopifyClient.Bulk.stream_results(operation)
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

  Operations are tracked by id (`bulkOperation(id:)`), not with the
  deprecated `currentBulkOperation`, so several can run for the same shop.

  ## Waiting: webhook or polling

  `await/3` polls with backoff, which is simple but spends a request per
  poll. At scale, subscribe to the `bulk_operations/finish` webhook instead:
  take the id from its payload with `webhook_operation_id/1`, then `get/2` it
  and `stream_results/3`.

  ## Nested results

  Nested connections come back as separate JSON lines, each child carrying a
  `"__parentId"`. `stream_results/3` yields the lines as they are.
  """

  alias ShopifyClient.Bulk.Operation
  alias ShopifyClient.Error

  @run_query """
  mutation ShopifyClientBulkOperationRunQuery($query: String!, $groupObjects: Boolean!) {
    bulkOperationRunQuery(query: $query, groupObjects: $groupObjects) {
      bulkOperation { #{Operation.fields()} }
      userErrors { field message code }
    }
  }
  """

  @get """
  query ShopifyClientBulkOperation($id: ID!) {
    bulkOperation(id: $id) { #{Operation.fields()} }
  }
  """

  @cancel """
  mutation ShopifyClientBulkOperationCancel($id: ID!) {
    bulkOperationCancel(id: $id) {
      bulkOperation { #{Operation.fields()} }
      userErrors { field message }
    }
  }
  """

  @await_schema NimbleOptions.new!(
                  interval: [
                    type: :pos_integer,
                    default: 1_000,
                    doc: "First wait between polls, in ms. Doubles after each poll."
                  ],
                  max_interval: [
                    type: :pos_integer,
                    default: 30_000,
                    doc: "Longest wait between polls, in ms."
                  ],
                  timeout: [
                    type: :pos_integer,
                    default: :timer.hours(1),
                    doc: "Give up after this long, in ms (the operation keeps running)."
                  ],
                  sleep: [type: {:fun, 1}, default: &Process.sleep/1, doc: false]
                )

  @doc """
  Starts a bulk query. `query` is the GraphQL query to run over the shop
  (without variables).

  Options: `group_objects: true` groups nested objects under their parents
  (slower; only when you need it). Other options go to `ShopifyClient.query/4`.
  """
  @spec run_query(ShopifyClient.client(), String.t(), keyword()) ::
          {:ok, Operation.t()} | {:error, Error.t()}
  def run_query(client, query, opts \\ []) do
    {group_objects, query_opts} = Keyword.pop(opts, :group_objects, false)
    variables = %{"query" => query, "groupObjects" => group_objects}

    with {:ok, response} <- ShopifyClient.query(client, @run_query, variables, query_opts) do
      {:ok, Operation.from_map(response.data["bulkOperationRunQuery"]["bulkOperation"])}
    end
  end

  @doc "Fetches a bulk operation by id (`{:ok, nil}` if it doesn't exist)."
  @spec get(ShopifyClient.client(), String.t(), keyword()) ::
          {:ok, Operation.t() | nil} | {:error, Error.t()}
  def get(client, id, opts \\ []) when is_binary(id) do
    with {:ok, response} <- ShopifyClient.query(client, @get, %{"id" => id}, opts) do
      {:ok, Operation.from_map(response.data["bulkOperation"])}
    end
  end

  @doc "Asks Shopify to cancel a running bulk operation."
  @spec cancel(ShopifyClient.client(), String.t() | Operation.t(), keyword()) ::
          {:ok, Operation.t()} | {:error, Error.t()}
  def cancel(client, id_or_operation, opts \\ []) do
    id = operation_id(id_or_operation)

    with {:ok, response} <- ShopifyClient.query(client, @cancel, %{"id" => id}, opts) do
      {:ok, Operation.from_map(response.data["bulkOperationCancel"]["bulkOperation"])}
    end
  end

  @doc """
  Polls until the operation finishes.

  Returns `{:ok, operation}` when it completed, or `{:error, %ShopifyClient.Error{}}`
  with `reason: :bulk_operation_failed` (the operation failed, was canceled
  or expired; it is in `:details`) or `reason: :timeout`.

  ## Options

  #{NimbleOptions.docs(@await_schema)}
  """
  @spec await(ShopifyClient.client(), String.t() | Operation.t(), keyword()) ::
          {:ok, Operation.t()} | {:error, Error.t()}
  def await(client, id_or_operation, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @await_schema)
    deadline = System.monotonic_time(:millisecond) + opts[:timeout]
    poll(client, operation_id(id_or_operation), opts[:interval], deadline, opts)
  end

  defp poll(client, id, interval, deadline, opts) do
    case get(client, id) do
      {:ok, %Operation{status: :completed} = operation} ->
        {:ok, operation}

      {:ok, %Operation{} = operation} ->
        if Operation.finished?(operation) do
          {:error,
           %Error{
             reason: :bulk_operation_failed,
             details: operation,
             message: "bulk operation #{id} ended #{operation.status} (#{operation.error_code})"
           }}
        else
          wait(client, id, interval, deadline, opts)
        end

      {:ok, nil} ->
        {:error, %Error{reason: :not_found, message: "bulk operation #{id} not found"}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp wait(client, id, interval, deadline, opts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, %Error{reason: :timeout, message: "bulk operation #{id} did not finish in time"}}
    else
      opts[:sleep].(min(interval, remaining))
      poll(client, id, min(interval * 2, opts[:max_interval]), deadline, opts)
    end
  end

  @doc """
  Streams a finished operation's results, one decoded JSON line at a time.
  The file is downloaded lazily, as the stream is consumed.

  A completed operation with no results has no `url`, and yields nothing.
  Pass `partial: true` to read `partial_data_url` from a failed operation.

  The download goes straight to Shopify's storage URL, using the client's
  adapter options (such as `:plug` in tests), but never the access token.
  """
  @spec stream_results(ShopifyClient.client(), Operation.t(), keyword()) :: Enumerable.t()
  def stream_results(client, %Operation{} = operation, opts \\ []) do
    url = if opts[:partial], do: operation.partial_data_url, else: operation.url

    case url do
      nil -> []
      url -> url |> download_chunks(client) |> decode_lines()
    end
  end

  @doc """
  The operation id from a `bulk_operations/finish` webhook payload.
  """
  @spec webhook_operation_id(map()) :: String.t() | nil
  def webhook_operation_id(%{"admin_graphql_api_id" => id}) when is_binary(id), do: id
  def webhook_operation_id(_payload), do: nil

  # A fresh request, not the client: the signed storage URL must not receive
  # the Shopify access token or the GraphQL request steps.
  @adapter_options [:plug, :finch, :connect_options, :receive_timeout, :pool_timeout, :inet6]

  # flat_map over the one URL keeps the request lazy (it runs when the stream
  # is first consumed), and accepts Req's async body, which is an Enumerable
  # of chunks rather than a list.
  defp download_chunks(url, client) do
    Stream.flat_map([url], fn url ->
      options =
        client
        |> ShopifyClient.__adapter_options__(@adapter_options)
        |> Map.to_list()
        |> Keyword.merge(url: url, into: :self)

      case Req.get(options) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          if is_binary(body), do: [body], else: body

        {:ok, %Req.Response{status: status}} ->
          raise %Error{
            reason: :http,
            status: status,
            message: "bulk results download returned HTTP #{status}"
          }

        {:error, exception} ->
          raise %Error{
            reason: :transport,
            details: exception,
            message: Exception.message(exception)
          }
      end
    end)
  end

  # Splits chunks into lines (a line can span chunks) and decodes each.
  @doc false
  def decode_lines(chunks) do
    chunks
    |> Stream.transform(
      fn -> "" end,
      fn chunk, buffer ->
        [rest | complete] = String.split(buffer <> chunk, "\n") |> Enum.reverse()
        {Enum.reverse(complete), rest}
      end,
      fn
        "" -> {[], ""}
        rest -> {[rest], ""}
      end,
      fn _buffer -> :ok end
    )
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
  end

  defp operation_id(%Operation{id: id}), do: id
  defp operation_id(id) when is_binary(id), do: id
end
