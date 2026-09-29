defmodule ShopifyClient.Application do
  @moduledoc false
  use Application

  # Owns the node-wide per-shop cost budget (ShopifyClient.Budget).
  @impl true
  def start(_type, _args) do
    Supervisor.start_link([ShopifyClient.Budget],
      strategy: :one_for_one,
      name: ShopifyClient.Supervisor
    )
  end
end
