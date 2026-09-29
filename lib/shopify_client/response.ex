defmodule ShopifyClient.Response do
  @moduledoc "A successful GraphQL response."

  @type t :: %__MODULE__{
          data: map(),
          extensions: map(),
          cost: ShopifyClient.Cost.t() | nil,
          status: non_neg_integer(),
          headers: %{optional(binary()) => [binary()]}
        }

  defstruct data: %{}, extensions: %{}, cost: nil, status: 200, headers: %{}
end
