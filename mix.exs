defmodule ShopifyClient.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/fluke/shopify_client_elixir"

  def project do
    [
      app: :shopify_client,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "A Shopify GraphQL Admin API client for Elixir, built on Req: per-shop cost budgets, " <>
          "cursor pagination as streams, and bulk operations.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ShopifyClient.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      # Req.Test stubs need Plug.
      {:plug, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
