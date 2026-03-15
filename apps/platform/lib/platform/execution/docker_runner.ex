defmodule Platform.Execution.DockerRunner do
  @moduledoc """
  Docker-backed `Platform.Execution.Runner` implementation.

  This provider keeps the existing BEAM-side control plane (`RunServer`,
  `ContextSession`, liveness state) and delegates the container mechanics to the
  companion `suite-runnerd` service through `SuiteRunnerdClient`.

  The goal of this first pass is to define a clean provider seam, not to invent
  a second orchestration plane. `RunServer` still owns the lifecycle state;
  `suite-runnerd` only owns spawn/describe/stop/kill for the concrete worker.
  """

  @behaviour Platform.Execution.Runner

  alias Platform.Execution.{CredentialLease, LocalWorkspace, Run, SuiteRunnerdClient}

  @default_client SuiteRunnerdClient

  @impl true
  def spawn_run(%Run{} = run, opts) do
    lease = Keyword.get(opts, :credential_lease)
    client = client_module(opts)
    client_opts = Keyword.get(opts, :client_opts, [])

    with {:ok, workspace} <- LocalWorkspace.ensure_workspace(run, opts),
         {:ok, command, args} <- resolve_command(run, opts),
         payload <- build_spawn_payload(run, workspace, command, args, lease, opts),
         {:ok, provider_ref} <- client.spawn_run(run, payload, client_opts) do
      {:ok,
       provider_ref
       |> normalize_provider_ref(run, workspace)
       |> Map.put(:command, command)
       |> Map.put(:args, args)}
    end
  end

  @impl true
  def request_stop(%Run{} = run, opts) do
    with {:ok, provider_ref} <- fetch_provider_ref(run),
         :ok <-
           client_module(opts).request_stop(
             run,
             provider_ref,
             Keyword.get(opts, :client_opts, [])
           ) do
      :ok
    end
  end

  @impl true
  def force_stop(%Run{} = run, opts) do
    with {:ok, provider_ref} <- fetch_provider_ref(run),
         :ok <-
           client_module(opts).force_stop(run, provider_ref, Keyword.get(opts, :client_opts, [])) do
      :ok
    end
  end

  @impl true
  def describe_run(%Run{} = run, opts) do
    with {:ok, provider_ref} <- fetch_provider_ref(run),
         {:ok, description} <-
           client_module(opts).describe_run(
             run,
             provider_ref,
             Keyword.get(opts, :client_opts, [])
           ) do
      {:ok, Map.merge(provider_ref, normalize_description(description))}
    end
  end

  @impl true
  def push_context(%Run{} = _run, _context, _opts), do: :ok

  defp client_module(opts), do: Keyword.get(opts, :client, @default_client)

  defp fetch_provider_ref(%Run{runner_ref: ref}) when is_map(ref) and map_size(ref) > 0,
    do: {:ok, normalize_provider_ref(ref)}

  defp fetch_provider_ref(_run), do: {:error, :missing_provider_ref}

  defp normalize_provider_ref(provider_ref, run \\ nil, workspace \\ nil)
       when is_map(provider_ref) do
    provider_ref =
      provider_ref
      |> atomize_keys(%{
        "provider" => :provider,
        "run_id" => :run_id,
        "workspace_root" => :workspace_root,
        "workspace_path" => :workspace_path,
        "container_id" => :container_id,
        "image" => :image,
        "status" => :status,
        "stop_mode" => :stop_mode,
        "exit_code" => :exit_code
      })
      |> Map.put_new(:provider, :docker)

    provider_ref =
      case run do
        %Run{} -> Map.put_new(provider_ref, :run_id, run.id)
        _ -> provider_ref
      end

    case workspace do
      %{root: root, path: path} ->
        provider_ref
        |> Map.put_new(:workspace_root, root)
        |> Map.put_new(:workspace_path, path)

      _ ->
        provider_ref
    end
  end

  defp atomize_keys(map, key_map) do
    Enum.reduce(key_map, map, fn {string_key, atom_key}, acc ->
      case Map.fetch(acc, string_key) do
        {:ok, value} -> acc |> Map.delete(string_key) |> Map.put(atom_key, value)
        :error -> acc
      end
    end)
  end

  defp build_spawn_payload(run, workspace, command, args, lease, opts) do
    %{
      run_id: run.id,
      task_id: run.task_id,
      project_id: run.project_id,
      epic_id: run.epic_id,
      workspace_root: workspace.root,
      workspace_path: workspace.path,
      command: command,
      args: args,
      env: build_env(lease),
      meta: Map.merge(run.meta, Enum.into(Keyword.get(opts, :meta_overrides, []), %{}))
    }
  end

  defp normalize_description(description) when is_map(description) do
    atomize_keys(description, %{
      "status" => :status,
      "exit_code" => :exit_code,
      "container_id" => :container_id,
      "image" => :image,
      "stop_mode" => :stop_mode
    })
  end

  defp resolve_command(%Run{} = run, opts) do
    case Keyword.get(opts, :command) || Map.get(run.meta, :command) ||
           Map.get(run.meta, "command") do
      nil ->
        {:error, :missing_command}

      command when is_binary(command) ->
        args =
          Keyword.get(opts, :args) ||
            Map.get(run.meta, :args) ||
            Map.get(run.meta, "args") ||
            []

        {:ok, command, Enum.map(List.wrap(args), &to_string/1)}
    end
  end

  defp build_env(nil), do: %{}
  defp build_env(%CredentialLease{} = lease), do: CredentialLease.to_env(lease)
end
