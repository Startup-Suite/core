defmodule Platform.Artifacts.PublicationResult do
  @moduledoc """
  Final outcome for a publication attempt.
  """

  @valid_statuses [:succeeded, :failed]

  @enforce_keys [:attempt_id, :artifact_id, :destination, :status]
  defstruct attempt_id: nil,
            artifact_id: nil,
            destination: nil,
            status: :succeeded,
            external_ref: nil,
            metadata: %{},
            error: nil,
            completed_at: nil

  @type t :: %__MODULE__{
          attempt_id: String.t(),
          artifact_id: String.t(),
          destination: String.t(),
          status: :succeeded | :failed,
          external_ref: String.t() | nil,
          metadata: map(),
          error: term(),
          completed_at: DateTime.t()
        }

  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = result), do: {:ok, normalize(result)}

  def new(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, attempt_id} <- fetch_string(attrs, :attempt_id, :missing_attempt_id),
         {:ok, artifact_id} <- fetch_string(attrs, :artifact_id, :missing_artifact_id),
         {:ok, destination} <- fetch_string(attrs, :destination, :missing_destination),
         {:ok, status} <- fetch_status(attrs) do
      {:ok,
       %__MODULE__{
         attempt_id: attempt_id,
         artifact_id: artifact_id,
         destination: destination,
         status: status,
         external_ref: fetch_optional_string(attrs, :external_ref),
         metadata: fetch_map(attrs, :metadata),
         error: fetch_value(attrs, :error),
         completed_at: normalize_datetime(fetch_value(attrs, :completed_at)) || DateTime.utc_now()
       }}
    end
  end

  def new(_other), do: {:error, :invalid_publication_result}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "attempt_id" => result.attempt_id,
      "artifact_id" => result.artifact_id,
      "destination" => result.destination,
      "status" => Atom.to_string(result.status),
      "external_ref" => result.external_ref,
      "metadata" => result.metadata,
      "error" => result.error,
      "completed_at" => DateTime.to_iso8601(result.completed_at)
    }
  end

  defp normalize(%__MODULE__{} = result) do
    %__MODULE__{
      result
      | metadata: normalize_map(result.metadata),
        completed_at: result.completed_at || DateTime.utc_now()
    }
  end

  defp fetch_status(attrs) do
    case fetch_value(attrs, :status) do
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
