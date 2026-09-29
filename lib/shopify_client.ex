defmodule ShopifyClient do
  query_options = [
    throttle: [
      type: {:in, [:wait, :fail_fast]},
      default: :wait,
      doc: "What to do when the shop's budget is short, or Shopify answers `THROTTLED`."
    ],
    max_wait: [
      type: :non_neg_integer,
      default: 30_000,
      doc: "With `throttle: :wait`, the longest single wait for budget, in ms."
    ],
    max_throttle_retries: [
      type: :non_neg_integer,
      default: 3,
      doc: "With `throttle: :wait`, how many times a `THROTTLED` answer is retried."
    ],
    cost_hint: [
      type: :pos_integer,
      default: 10,
      doc: "Points a request is assumed to need when checking the budget before sending."
    ],
    user_errors: [
      type: {:in, [:error, :ignore]},
      default: :error,
      doc:
        "`:error` turns non-empty mutation `userErrors` into `{:error, %ShopifyClient.Error{reason: :user_errors}}`."
    ],
    sleep: [type: {:fun, 1}, default: &Process.sleep/1, doc: false]
  ]

  client_options =
    [
      shop: [
        type: :string,
        required: true,
        doc: "The shop's myshopify.com domain (`example.myshopify.com`, or just `example`)."
      ],
      access_token: [
        type: :string,
        required: true,
        doc: "The shop's Admin API access token. Never shown by `inspect/1`."
      ],
      api_version: [
        type: :string,
        required: true,
        doc: ~s{The Admin API version, like `"2026-04"`. Deliberately has no default.}
      ],
      app_name: [
        type: :string,
        doc: "Prepended to the `user-agent` header, to identify your app to Shopify."
      ],
      req_options: [
        type: :keyword_list,
        default: [],
        doc: "Extra `Req` options, for `new/1`."
      ]
    ] ++ query_options

  @query_schema NimbleOptions.new!(query_options)
  @client_schema NimbleOptions.new!(client_options)
  @query_option_keys Keyword.keys(query_options)

  @moduledoc """
  A client for Shopify's GraphQL Admin API, built on `Req`.

      client =
        ShopifyClient.new(
          shop: "example.myshopify.com",
          access_token: token,
          api_version: "2026-04"
        )

      {:ok, %ShopifyClient.Response{data: data}} =
        ShopifyClient.query(client, "query { shop { name } }")

  A client is a plain `%Req.Request{}`, so every Req option and step still
  applies (`ShopifyClient.new(req_options: [receive_timeout: 5_000])`, or
  `Req.new(...) |> ShopifyClient.attach(...)`).

  ## Throttling

  Shopify rate-limits each shop with a bucket of cost points. The client
  records every response's throttle status in a node-wide per-shop budget
  (`ShopifyClient.Budget`) and checks it *before* sending. What happens when
  the budget is short, or Shopify answers `THROTTLED`, is the `:throttle`
  option:

    * `:wait` (default) - sleep until enough points are back (at most
      `:max_wait` ms each time) and send, retrying a `THROTTLED` answer up to
      `:max_throttle_retries` times.
    * `:fail_fast` - never sleep: return
      `{:error, %ShopifyClient.Error{reason: :throttled}}` immediately, for
      callers with a better fallback than waiting.

  A throttled request never ran, so retrying it is always safe. Transport
  errors and 5xx responses are *not* retried: the operation may have run.

  ## Errors

  Every failure is a `ShopifyClient.Error`, whose `:reason` says what went
  wrong: top-level GraphQL errors, mutation `userErrors`, a shop that is
  uninstalled or frozen, a transport failure.

  ## Telemetry

  See `ShopifyClient.Telemetry`.

  ## Options

  #{NimbleOptions.docs(@client_schema)}
  """

  alias ShopifyClient.{Budget, Cost, Error, Response}

  require Logger

  @api_version_format ~r/\A(\d{4}-\d{2}|unstable)\z/
  @shop_format ~r/\A[a-z0-9][a-z0-9-]*\.myshopify\.com\z/
  @operation_name ~r/\A\s*(?:query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)/
  @version Mix.Project.config()[:version]

  @type client :: Req.Request.t()

  @doc """
  Builds a client. See the options in the module docs; the throttle and
  `:user_errors` options become the defaults for every `query/4` on it.
  """
  @spec new(keyword()) :: client()
  def new(opts) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    req_options |> Req.new() |> attach(opts)
  end

  @doc "Attaches the Shopify GraphQL client to an existing `Req.Request`."
  @spec attach(Req.Request.t(), keyword()) :: client()
  def attach(%Req.Request{} = request, opts) do
    opts = NimbleOptions.validate!(opts, @client_schema)
    shop = normalize_shop!(opts[:shop])
    api_version = validate_api_version!(opts[:api_version])
    token = opts[:access_token]

    config = %{
      shop: shop,
      api_version: api_version,
      # A closure, so `inspect/1` of the client (in logs, crash reports) shows
      # `#Function<...>` instead of the token. Req only redacts `authorization`.
      token: fn -> token end,
      query_opts: Keyword.take(opts, @query_option_keys)
    }

    request
    |> Req.merge(
      method: :post,
      base_url: "https://#{shop}/admin/api/#{api_version}",
      url: "/graphql.json",
      # Throttling is handled by query/4. Req's own retries could resend a
      # mutation after a transport error, when it may already have run.
      retry: false
    )
    |> Req.Request.put_header("user-agent", user_agent(opts[:app_name]))
    |> Req.Request.put_private(:shopify_client, config)
    |> Req.Request.prepend_request_steps(shopify_client_token: &put_token/1)
  end

  @doc """
  Runs a GraphQL query or mutation.

  Returns `{:ok, %ShopifyClient.Response{}}` or `{:error, %ShopifyClient.Error{}}`.
  `opts` override the client's throttle and `:user_errors` options for this call.
  """
  @spec query(client(), String.t(), map(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def query(%Req.Request{} = client, query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) do
    config = fetch_config!(client)
    opts = NimbleOptions.validate!(Keyword.merge(config.query_opts, opts), @query_schema)

    metadata = %{
      shop: config.shop,
      api_version: config.api_version,
      operation: operation_name(query)
    }

    :telemetry.span([:shopify_client, :query], metadata, fn ->
      result = run(client, config.shop, %{query: query, variables: variables}, opts, 0)
      {result, Map.merge(metadata, result_metadata(result))}
    end)
  end

  @doc "Like `query/4`, but returns the response or raises `ShopifyClient.Error`."
  @spec query!(client(), String.t(), map(), keyword()) :: Response.t()
  def query!(client, query, variables \\ %{}, opts \\ []) do
    case query(client, query, variables, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  Streams every node of a paginated connection, fetching pages lazily. See
  `ShopifyClient.Pagination.stream/4`.
  """
  defdelegate stream(client, query, variables \\ %{}, opts), to: ShopifyClient.Pagination

  @doc "The shop (myshopify.com domain) a client talks to."
  @spec shop(client()) :: String.t()
  def shop(client), do: fetch_config!(client).shop

  # -- running a request ----------------------------------------------------------

  defp run(client, shop, body, opts, attempt) do
    with :ok <- await_budget(shop, opts[:cost_hint], opts) do
      send_and_retry(client, shop, body, opts, attempt)
    end
  end

  defp send_and_retry(client, shop, body, opts, attempt) do
    case send_request(client, shop, body, opts) do
      {:error, %Error{reason: :throttled} = error} ->
        retry_throttled(client, shop, body, opts, attempt, error)

      result ->
        result
    end
  end

  # Waits until the query's requested cost is back, then resends directly: the
  # wait already accounts for the budget, so it isn't checked again.
  defp retry_throttled(client, shop, body, opts, attempt, error) do
    needed = (error.cost && error.cost.requested) || opts[:cost_hint]
    wait = Budget.wait_ms(shop, needed)

    if opts[:throttle] == :wait and attempt < opts[:max_throttle_retries] and
         wait <= opts[:max_wait] do
      throttle_event(shop, wait, :throttled)
      opts[:sleep].(wait)
      send_and_retry(client, shop, body, opts, attempt + 1)
    else
      {:error, error}
    end
  end

  # Before sending: is the shop's bucket (as far as we know) too low?
  defp await_budget(shop, points, opts) do
    wait = Budget.wait_ms(shop, points)

    cond do
      wait == 0 ->
        :ok

      opts[:throttle] == :wait and wait <= opts[:max_wait] ->
        throttle_event(shop, wait, :budget)
        opts[:sleep].(wait)
        :ok

      true ->
        {:error,
         %Error{
           reason: :throttled,
           details: :budget,
           message:
             "Shopify budget for #{shop} is short: about #{wait}ms until #{points} points are available"
         }}
    end
  end

  defp send_request(client, shop, body, opts) do
    case Req.request(client, json: body) do
      {:ok, response} ->
        cost = Cost.from_body(response.body)
        Budget.record(shop, cost)
        warn_if_deprecated(response, shop)
        handle_response(response, cost, opts)

      {:error, exception} ->
        {:error,
         %Error{reason: :transport, details: exception, message: Exception.message(exception)}}
    end
  end

  # -- response handling ------------------------------------------------------------

  defp handle_response(%Req.Response{status: 200, body: %{} = body} = response, cost, opts) do
    case body do
      %{"errors" => [_ | _] = errors} ->
        {:error, graphql_error(errors, cost, response)}

      %{"data" => data} when is_map(data) ->
        success = %Response{
          data: data,
          extensions: body["extensions"] || %{},
          cost: cost,
          status: 200,
          headers: response.headers
        }

        check_user_errors(success, opts[:user_errors])

      _other ->
        {:error, http_error(:http, response, "Unexpected GraphQL response body")}
    end
  end

  defp handle_response(%Req.Response{status: 200} = response, _cost, _opts),
    do: {:error, http_error(:http, response, "Unexpected non-JSON response body")}

  defp handle_response(%Req.Response{status: status} = response, _cost, _opts) do
    reason =
      case status do
        401 -> :unauthorized
        402 -> :payment_required
        403 -> :forbidden
        404 -> :not_found
        423 -> :locked
        429 -> :throttled
        status when status >= 500 -> :server_error
        _other -> :http
      end

    {:error, http_error(reason, response, "Shopify responded with HTTP #{status}")}
  end

  defp graphql_error(errors, cost, response) do
    codes = Enum.map(errors, &get_in(&1, ["extensions", "code"]))

    reason =
      cond do
        "THROTTLED" in codes -> :throttled
        "ACCESS_DENIED" in codes -> :access_denied
        "MAX_COST_EXCEEDED" in codes -> :max_cost_exceeded
        true -> :graphql
      end

    %Error{
      reason: reason,
      errors: errors,
      cost: cost,
      status: response.status,
      message: join_messages(errors)
    }
  end

  defp http_error(reason, response, message) do
    %Error{reason: reason, status: response.status, details: response.body, message: message}
  end

  # Mutation payloads carry `userErrors` next to their result. With
  # `user_errors: :error`, any non-empty list fails the call.
  defp check_user_errors(response, :ignore), do: {:ok, response}

  defp check_user_errors(%Response{data: data} = response, :error) do
    user_errors =
      for {_root, %{"userErrors" => [_ | _] = errors}} <- data, error <- errors, do: error

    case user_errors do
      [] ->
        {:ok, response}

      errors ->
        {:error,
         %Error{
           reason: :user_errors,
           errors: errors,
           cost: response.cost,
           status: 200,
           response: response,
           message: join_messages(errors)
         }}
    end
  end

  defp join_messages(errors),
    do: errors |> Enum.map(&(&1["message"] || inspect(&1))) |> Enum.join("; ")

  # -- helpers ------------------------------------------------------------------------

  defp put_token(request) do
    %{token: token} = request.private.shopify_client
    Req.Request.put_header(request, "x-shopify-access-token", token.())
  end

  defp fetch_config!(%Req.Request{private: %{shopify_client: config}}), do: config

  defp fetch_config!(%Req.Request{}) do
    raise ArgumentError,
          "not a ShopifyClient client: build one with ShopifyClient.new/1 or ShopifyClient.attach/2"
  end

  @doc false
  def normalize_shop!(shop) do
    normalized =
      shop
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r{\Ahttps?://}, "")
      |> String.trim_trailing("/")
      |> then(&if String.contains?(&1, "."), do: &1, else: &1 <> ".myshopify.com")

    # Only myshopify.com hosts: the access token is sent to this host.
    if normalized =~ @shop_format do
      normalized
    else
      raise ArgumentError,
            "expected a myshopify.com shop domain like \"example.myshopify.com\", got: #{inspect(shop)}"
    end
  end

  defp validate_api_version!(version) do
    if version =~ @api_version_format do
      version
    else
      raise ArgumentError,
            ~s{expected an API version like "2026-04" (or "unstable"), got: #{inspect(version)}}
    end
  end

  defp user_agent(nil), do: "shopify_client/#{@version} (Elixir; Req)"
  defp user_agent(app_name), do: "#{app_name} shopify_client/#{@version} (Elixir; Req)"

  @doc false
  def operation_name(query) do
    case Regex.run(@operation_name, query) do
      [_match, name] -> name
      nil -> nil
    end
  end

  defp result_metadata({:ok, %Response{cost: cost}}), do: %{result: :ok, cost: cost}

  defp result_metadata({:error, %Error{reason: reason, cost: cost}}),
    do: %{result: {:error, reason}, cost: cost}

  defp throttle_event(shop, wait_ms, cause) do
    :telemetry.execute([:shopify_client, :throttle], %{wait_ms: wait_ms}, %{
      shop: shop,
      cause: cause
    })
  end

  # Shopify flags deprecated API usage with a response header. Warn once per
  # distinct reason for the lifetime of the node; emit telemetry every time.
  defp warn_if_deprecated(response, shop) do
    case Req.Response.get_header(response, "x-shopify-api-deprecated-reason") do
      [reason | _] ->
        :telemetry.execute([:shopify_client, :deprecated], %{}, %{shop: shop, reason: reason})
        key = {__MODULE__, :deprecated, reason}

        unless :persistent_term.get(key, false) do
          :persistent_term.put(key, true)
          Logger.warning("[shopify_client] Shopify flagged deprecated API usage: #{reason}")
        end

      [] ->
        :ok
    end
  end
end
