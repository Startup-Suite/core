defmodule Platform.Artifacts.Publisher do
  @moduledoc """
  Runs artifact publication through a destination module while recording the
  immutable artifact, publication attempt, and final result as separate records.
  """

  alias Platform.Artifacts
  alias Platform.Artifacts.{Artifact, PublicationResult}

  @spec publish(Artifact.t() | String.t(), module(), keyword()) ::
          {:ok, %{artifact: Artifact.t(), attempt: Platform.Artifacts.PublicationAttempt.t(), result: PublicationResult.t()}}
          | {:error, term(), %{artifact: Artifact.t(), attempt: Platform.Artifacts.PublicationAttempt.t(), result: PublicationResult.t()}}
          | {:error, term()}
  def publish(artifact_or_id, destination, opts \\ []) when is_atom(destination) do
    with {:ok, artifact} <- resolve_artifact(artifact_or_id),
         destination_key when is_binary(destination_key) <- destination.destination_key(opts),
         {:ok, attempt} <- Artifacts.record_attempt(attempt_attrs(artifact, destination_key, opts)) do
      case destination.publish(artifact, attempt, opts) do
        {:ok, result_input} ->
          with {:ok, result} <- record_success(attempt, artifact, destination_key, result_input) do
            {:ok, %{artifact: artifact, attempt: attempt, result: result}}
          end

        {:error, reason} ->
          with {:ok, result} <- record_failure(attempt, artifact, destination_key, reason, opts) do
            {:error, reason, %{artifact: artifact, attempt: attempt, result: result}}
          end
      end
    end
  end

  defp resolve_artifact(%Artifact{} = artifact), do: {:ok, artifact}
  defp resolve_artifact(id) when is_binary(id), do: Artifacts.fetch(id)
  defp resolve_artifact(_other), do: {:error, :invalid_artifact}

  defp attempt_attrs(artifact, destination_key, opts) do
    %{
      id: Keyword.get(opts, :attempt_id, Ecto.UUID.generate()),
      artifact_id: artifact.id,
      destination: destination_key,
      requested_by: normalize_requested_by(opts),
      metadata: normalize_metadata(Keyword.get(opts, :attempt_metadata, %{}))
    }
  end

  defp record_success(attempt, artifact, destination_key, result_input) do
    normalized = normalize_result_input(result_input)

    normalized
    |> Map.merge(%{
      attempt_id: attempt.id,
      artifact_id: artifact.id,
      destination: destination_key,
      status: Map.get(normalized, :status, Map.get(normalized, "status", :succeeded))
    })
    |> Artifacts.record_result()
  end

  defp record_failure(attempt, artifact, destination_key, reason, opts) do
    Artifacts.record_result(%{
      attempt_id: attempt.id,
      artifact_id: artifact.id,
      destination: destination_key,
      status: :failed,
      error: normalize_error(reason),
      metadata: normalize_metadata(Keyword.get(opts, :failure_metadata, %{}))
    })
  end

  defp normalize_result_input(%PublicationResult{} = result), do: PublicationResult.to_map(result)
  defp normalize_result_input(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> normalize_result_input()
  defp normalize_result_input(%{} = attrs), do: attrs
  defp normalize_result_input(_other), do: %{}

  defp normalize_requested_by(opts) do
    case Keyword.get(opts, :requested_by) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_other), do: %{}

  defp normalize_error(%{} = error), do: error
  defp normalize_error(error), do: %{message: inspect(error)}
end
