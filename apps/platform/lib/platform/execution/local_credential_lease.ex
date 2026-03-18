defmodule Platform.Execution.LocalCredentialLease do
  @moduledoc """
  Lightweight credential materialization for local execution runs.

  The local provider currently supports leasing credentials into the child
  process environment. Literal values can be passed directly, and follow-up
  work can swap in Vault-backed lease specs without changing the runner
  contract.
  """

  alias Platform.Execution.Run

  @type lease_bundle :: %{
          env: %{optional(String.t()) => String.t()},
          env_keys: [String.t()]
        }

  @spec build(Run.t(), keyword()) :: {:ok, lease_bundle()} | {:error, term()}
  def build(%Run{} = run, opts \\ []) do
    literal_env =
      opts
      |> Keyword.get(:leased_env, metadata_value(run, :leased_env, %{}))
      |> normalize_env_map()

    extra_env =
      opts
      |> Keyword.get(:env, metadata_value(run, :env, %{}))
      |> normalize_env_map()

    with {:ok, spec_env} <- resolve_specs(metadata_or_opt(opts, run, :credential_leases)) do
      env =
        literal_env
        |> Map.merge(extra_env)
        |> Map.merge(spec_env)

      {:ok, %{env: env, env_keys: env |> Map.keys() |> Enum.sort()}}
    end
  end

  defp metadata_or_opt(opts, run, key) do
    Keyword.get(opts, key, metadata_value(run, key, []))
  end

  defp metadata_value(%Run{metadata: metadata}, key, default) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end

  defp normalize_env_map(nil), do: %{}

  defp normalize_env_map(%{} = env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_env_map(_other), do: %{}

  defp resolve_specs(nil), do: {:ok, %{}}
  defp resolve_specs([]), do: {:ok, %{}}

  defp resolve_specs(specs) when is_list(specs) do
    Enum.reduce_while(specs, {:ok, %{}}, fn spec, {:ok, acc} ->
      case resolve_spec(spec) do
        {:ok, {env_key, env_value}} -> {:cont, {:ok, Map.put(acc, env_key, env_value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_specs(_other), do: {:error, :invalid_credential_leases}

  defp resolve_spec(%{} = spec) do
    env_key = fetch(spec, :env) || fetch(spec, :name)

    cond do
      is_nil(env_key) ->
        {:error, :missing_env_name}

      value = fetch(spec, :value) ->
        {:ok, {to_string(env_key), to_string(value)}}

      slug = fetch(spec, :vault_slug) || fetch(spec, :credential_slug) || fetch(spec, :slug) ->
        resolve_vault_spec(to_string(env_key), to_string(slug), fetch(spec, :accessor))

      true ->
        {:error, {:invalid_credential_lease, spec}}
    end
  end

  defp resolve_spec(_other), do: {:error, :invalid_credential_lease}

  defp resolve_vault_spec(env_key, slug, accessor) do
    opts = if accessor, do: [accessor: accessor], else: []

    case Platform.Vault.get(slug, opts) do
      {:ok, value} ->
        case extract_secret(value) do
          {:ok, secret} -> {:ok, {env_key, secret}}
          {:error, reason} -> {:error, {:invalid_vault_lease_value, slug, reason}}
        end

      {:error, reason} ->
        {:error, {:vault_lookup_failed, slug, reason}}
    end
  end

  defp extract_secret(value) when is_binary(value), do: {:ok, value}

  defp extract_secret(value) when is_integer(value) or is_float(value),
    do: {:ok, to_string(value)}

  defp extract_secret(%{} = value) do
    cond do
      token = fetch(value, :token) -> {:ok, to_string(token)}
      token = fetch(value, :access_token) -> {:ok, to_string(token)}
      token = fetch(value, :api_key) -> {:ok, to_string(token)}
      token = fetch(value, :value) -> {:ok, to_string(token)}
      true -> {:error, :unsupported_map_value}
    end
  end

  defp extract_secret(_other), do: {:error, :unsupported_value}

  defp fetch(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
