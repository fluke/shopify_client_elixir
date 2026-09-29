defmodule ShopifyClient.Bulk.Operation do
  @moduledoc "A Shopify bulk operation (`BulkOperation`)."

  @type status ::
          :created
          | :running
          | :completed
          | :canceling
          | :canceled
          | :failed
          | :expired
          | String.t()

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          type: String.t() | nil,
          error_code: String.t() | nil,
          query: String.t() | nil,
          url: String.t() | nil,
          partial_data_url: String.t() | nil,
          object_count: non_neg_integer() | nil,
          root_object_count: non_neg_integer() | nil,
          file_size: non_neg_integer() | nil,
          created_at: String.t() | nil,
          completed_at: String.t() | nil
        }

  defstruct [
    :id,
    :status,
    :type,
    :error_code,
    :query,
    :url,
    :partial_data_url,
    :object_count,
    :root_object_count,
    :file_size,
    :created_at,
    :completed_at
  ]

  @doc false
  def fields do
    "id status type errorCode query url partialDataUrl objectCount rootObjectCount fileSize createdAt completedAt"
  end

  # Mapped explicitly rather than String.to_atom/1: never create atoms from
  # response data. An unknown future status stays a string.
  @statuses %{
    "CREATED" => :created,
    "RUNNING" => :running,
    "COMPLETED" => :completed,
    "CANCELING" => :canceling,
    "CANCELED" => :canceled,
    "FAILED" => :failed,
    "EXPIRED" => :expired
  }

  @terminal [:completed, :canceled, :failed, :expired]

  @doc false
  def from_map(nil), do: nil

  def from_map(%{} = map) do
    %__MODULE__{
      id: map["id"],
      status: Map.get(@statuses, map["status"], map["status"]),
      type: map["type"],
      error_code: map["errorCode"],
      query: map["query"],
      url: map["url"],
      partial_data_url: map["partialDataUrl"],
      # UnsignedInt64 is serialized as a string.
      object_count: to_integer(map["objectCount"]),
      root_object_count: to_integer(map["rootObjectCount"]),
      file_size: to_integer(map["fileSize"]),
      created_at: map["createdAt"],
      completed_at: map["completedAt"]
    }
  end

  @doc "Whether the operation has finished, successfully or not."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: status}), do: status in @terminal

  defp to_integer(nil), do: nil
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)
end
