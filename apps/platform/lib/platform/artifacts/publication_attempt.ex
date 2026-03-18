defmodule Platform.Artifacts.PublicationAttempt do
  @moduledoc """
  Requested publication of an artifact to a destination.
  """

  @valid_statuses [:pending, :running, :succeeded, :failed]

  @enforce_keys [:id, :artifact_id, :destination]
  defstruct id: nil,
            artifact_id: nil,
            destination: nil,
            status: :pending,
            requested_by: nil,
            metadata: %{},
            inserted_at: nil

  @type t :: %__MODULE__{
          id: String.t(),
          artifact_id: String.t(),
          destination: String.t(),
          status: :pending | :running | :succeeded | :failed,
          requested_by: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t()
        }

  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = attempt), do: {:ok, normalize(attempt)}

  def new(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_string(attrs, :id, :missing_id),
         {:ok, artifact_id} <- fetch_string(attrs, :artifact_id, :missing_artifact_id),
         {:ok, destination} <- fetch_string(attrs, :destination, :missing_destination),
         {:ok, status} <- fetch_status(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         artifact_id: artifact_id,
         destination: destination,
         status: status,
         requested_by: fetch_optional_string(attrs, :requested_by),
         metadata: fetch_map(attrs, :metadata),
         inserted_at: normalize_datetime(fetch_value(attrs, :inserted_at)) || DateTime.utc_now()
       }}
    end
  end

  def new(_other), do: {:error, :invalid_publication_attempt}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = attempt) do
    %{
      "id" => attempt.id,
      "artifact_id" => attempt.artifact_id,
      "destination" => attempt.destination,
      "status" => Atom.to_string(attempt.status),
      "requested_by" => attempt.requested_by,
      "metadata" => attempt.metadata,
      "inserted_at" => DateTime.to_iso8601(attempt.inserted_at)
    }
  end

  defp normalize(%__MODULE__{} = attempt) do
    %__MODULE__{
      attempt
      | metadata: normalize_map(attempt.metadata),
        inserted_at: attempt.inserted_at || DateTime.utc_now()
    }
  end

  defp fetch_status(attrs) do
    case fetch_value(attrs, :status, :pending) do
      value when is_atom(value) ->
        if value in @valid_statuses, do: {:ok, value}, else: {:error, :invalid_status}

      value when is_binary(value) ->
        parse_status(value)

      _ ->
        {:error, :invalid_status}
    end
  end

  defp parse_status(value) do
    try do
      normalized =
        value
        |> String.trim()
        |> String.downcase()
        |> String.to_existing_atom()

      if normalized in @valid_statuses, do: {:ok, normalized}, else: {:error, :invalid_status}
    rescue
      _ -> {:error, :invalid_status}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp fetch_string(attrs, key, error) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when not is_nil(value) -> {:ok, to_string(value)}
      _ -> {:error, error}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> nil
      "" -> nil
      value -> to_string(value)
    end
  end

  defp fetch_map(attrs, key), do: attrs |> fetch_value(key, %{}) |> normalize_map()

  defp normalize_map(%{} = value), do: value
  defp normalize_map(_other), do: %{}

  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp normalize_datetime(_other), do: nil
end
