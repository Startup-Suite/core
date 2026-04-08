defmodule Platform.Org.ContextSeeder do
  @moduledoc """
  Seeds default org context files on first boot.
  Only inserts files that do not already exist (idempotent).
  """
  import Ecto.Query
  alias Platform.Org.ContextFile
  alias Platform.Repo

  @default_files %{
    "ORG_IDENTITY.md" => "# Organization Identity\n\nDescribe your organization here.\n",
    "ORG_MEMORY.md" => "# Organization Memory\n\nShared long-term memory for the organization.\n",
    "ORG_AGENTS.md" => "# Organization Agents\n\nShared agent guidelines and conventions.\n",
    "ORG_DIRECTORY.md" => "# Organization Directory\n\nTeam members, roles, and contact info.\n"
  }

  @doc "Seed default org context files. Idempotent — skips files that already exist."
  def seed_defaults(workspace_id \\ nil) do
    existing_keys =
      ContextFile
      |> where([cf], cf.workspace_id == ^workspace_id)
      |> select([cf], cf.file_key)
      |> Repo.all()
      |> MapSet.new()

    Enum.each(@default_files, fn {file_key, content} ->
      unless MapSet.member?(existing_keys, file_key) do
        %ContextFile{}
        |> ContextFile.changeset(%{
          workspace_id: workspace_id,
          file_key: file_key,
          content: content
        })
        |> Repo.insert!()
      end
    end)

    :ok
  end
end
