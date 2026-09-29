defmodule ShopifyClient.Pagination do
  @moduledoc """
  Cursor pagination as a lazy `Stream`.

      query = \"""
      query Products($cursor: String) {
        products(first: 250, after: $cursor) {
          nodes { id title }
          pageInfo { hasNextPage endCursor }
        }
      }
      \"""

      client
      |> ShopifyClient.stream(query, %{}, path: ["products"])
      |> Stream.filter(&(&1["title"] =~ "Sale"))
      |> Enum.take(10)

  Pages are fetched only as the stream is consumed, so `Enum.take/2` above
  stops after the first page that yields ten matches. The connection must
  select `pageInfo { hasNextPage endCursor }`, and either `nodes` or
  `edges { node }`. The cursor is passed as the `$cursor` variable (see
  `:cursor_variable`).

  A failed page raises `ShopifyClient.Error` (a stream has nowhere to return
  an error tuple). Throttling is handled by `ShopifyClient.query/4` as usual,
  so a long stream waits between pages when the shop's budget runs low.
  """

  alias ShopifyClient.Error

  @schema NimbleOptions.new!(
            path: [
              type: {:list, :string},
              required: true,
              doc: ~s{Where the connection is in `data`, like `["products"]`.}
            ],
            cursor_variable: [
              type: :string,
              default: "cursor",
              doc: "The query variable that takes the page cursor."
            ]
          )

  @doc """
  Streams every node of the connection at `:path`.

  ## Options

  #{NimbleOptions.docs(@schema)}

  Any other option is passed to `ShopifyClient.query/4` for every page.
  """
  @spec stream(ShopifyClient.client(), String.t(), map(), keyword()) :: Enumerable.t()
  def stream(client, query, variables \\ %{}, opts) do
    {stream_opts, query_opts} = Keyword.split(opts, [:path, :cursor_variable])
    stream_opts = NimbleOptions.validate!(stream_opts, @schema)

    unless query =~ "pageInfo" do
      raise ArgumentError,
            "the query must select pageInfo { hasNextPage endCursor } on the paginated connection"
    end

    Stream.resource(
      fn -> {:next, nil} end,
      fn
        :done ->
          {:halt, :done}

        {:next, cursor} ->
          variables = Map.put(variables, stream_opts[:cursor_variable], cursor)
          fetch_page(client, query, variables, query_opts, stream_opts[:path])
      end,
      fn _acc -> :ok end
    )
  end

  defp fetch_page(client, query, variables, query_opts, path) do
    case ShopifyClient.query(client, query, variables, query_opts) do
      {:ok, response} ->
        connection = get_in(response.data, path) || %{}
        page_info = connection["pageInfo"] || %{}

        next =
          if page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]),
            do: {:next, page_info["endCursor"]},
            else: :done

        {nodes(connection), next}

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp nodes(%{"edges" => edges}) when is_list(edges), do: Enum.map(edges, & &1["node"])
  defp nodes(_connection), do: []
end
