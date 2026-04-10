defmodule Platform.Org.Context do
  @moduledoc """
  Context module for org-level context file management.

  Provides CRUD operations for shared organizational knowledge files
  like ORG_IDENTITY.md, ORG_MEMORY.md, ORG_AGENTS.md, etc.

  ## Quick reference

      Platform.Org.Context.list_files()
      Platform.Org.Context.get_file("ORG_IDENTITY.md")
      Platform.Org.Context.upsert_file(%{file_key: "ORG_IDENTITY.md", content: "# Our Org", updated_by: user_id})
      Platform.Org.Context.delete_file("CUSTOM_FILE.md")
  """

  import Ecto.Query

  alias Platform.Org.ContextFile
  alias Platform.Org.MemoryEntry
  alias Platform.Repo

  @default_templates %{
    "ORG_IDENTITY.md" => """
    # Organization Identity

    ## Mission
    _What is your organization's mission?_

    ## Values
    _What principles guide your team?_

    ## Product Summary
    _Brief description of what you're building._

    ## Team
    _Who are the key people and what are their roles?_
    """,
    "ORG_MEMORY.md" => """
    # Organization Memory

    Long-term curated knowledge for the organization. Agents reference this
    for persistent context about decisions, patterns, and institutional knowledge.

    ## Key Decisions
    _Record important decisions and their rationale here._

    ## Patterns & Conventions
    _Document recurring patterns, naming conventions, and standards._

    ## Lessons Learned
    _Capture insights from past experiences._
    """,
    "ORG_AGENTS.md" => """
    # Organization Agents

    Registry of agents and their roles within the organization.

    ## Active Agents

    | Agent | Role | Capabilities |
    |-------|------|-------------|
    | _agent-name_ | _role_ | _what it does_ |

    ## Agent Guidelines
    _Shared guidelines for how agents should behave._
    """,
    "ORG_DIRECTORY.md" => """
    # Organization Directory

    Auto-generated roster of users and agents. This file is maintained
    automatically — manual edits may be overwritten.

    ## Users
    _Auto-populated from the user registry._

    ## Agents
    _Auto-populated from the agent registry._
    """
  }

  @doc "Returns the default template content for a given file key, or nil."
  def default_template(file_key), do: Map.get(@default_templates, file_key)

  @doc "Returns the map of all default templates."
  def default_templates, do: @default_templates

  @doc "Lists all org context files, ordered by file_key."
  def list_files(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    ContextFile
    |> maybe_filter_workspace(workspace_id)
    |> order_by([f], asc: f.file_key)
    |> Repo.all()
  end

  @doc "Gets a single org context file by its file_key."
  def get_file(file_key, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    ContextFile
    |> where([f], f.file_key == ^file_key)
    |> maybe_filter_workspace(workspace_id)
    |> Repo.one()
  end

  @doc "Gets a single org context file by ID."
  def get_file_by_id(id) do
    Repo.get(ContextFile, id)
  end

  @doc """
  Creates or updates an org context file. On update, the version is incremented.
  """
  def upsert_file(attrs) do
    file_key = Map.get(attrs, :file_key) || Map.get(attrs, "file_key")

    case get_file(file_key) do
      nil ->
        %ContextFile{}
        |> ContextFile.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> ContextFile.changeset(%{
          content: Map.get(attrs, :content) || Map.get(attrs, "content"),
          updated_by: Map.get(attrs, :updated_by) || Map.get(attrs, "updated_by"),
          version: existing.version + 1
        })
        |> Repo.update()
    end
  end

  @doc "Deletes a context file. Returns {:ok, file} or {:error, changeset}."
  def delete_file(file_key) do
    case get_file(file_key) do
      nil -> {:error, :not_found}
      file -> Repo.delete(file)
    end
  end

  @doc """
  Seeds default org context files if they don't already exist.
  Typically called during application startup or from a migration seed.
  """
  def seed_defaults(opts \\ []) do
    updated_by = Keyword.get(opts, :updated_by)

    Enum.each(@default_templates, fn {file_key, template} ->
      case get_file(file_key) do
        nil ->
          %ContextFile{}
          |> ContextFile.changeset(%{
            file_key: file_key,
            content: template,
            updated_by: updated_by
          })
          |> Repo.insert!()

        _exists ->
          :ok
      end
    end)
  end

  # ── Memory Entries ────────────────────────────────────────────────────

  @doc """
  Searches org memory entries with optional filters.

  ## Options
    * `:query` - text search within content (ILIKE)
    * `:memory_type` - filter by "daily" or "long_term"
    * `:date_from` - entries on or after this date
    * `:date_to` - entries on or before this date
    * `:workspace_id` - scope to workspace
    * `:limit` - max entries (default 50)
  """
  def search_memory(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    MemoryEntry
    |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
    |> maybe_filter_memory_type(Keyword.get(opts, :memory_type))
    |> maybe_filter_date_from(Keyword.get(opts, :date_from))
    |> maybe_filter_date_to(Keyword.get(opts, :date_to))
    |> maybe_filter_query(Keyword.get(opts, :query))
    |> order_by([e], desc: e.date, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Appends a new memory entry."
  def append_memory(attrs) do
    %MemoryEntry{}
    |> MemoryEntry.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Returns recent memory entries grouped by date (last N days)."
  def recent_memory(days \\ 7, opts \\ []) do
    date_from = Date.add(Date.utc_today(), -days)

    search_memory(Keyword.merge(opts, date_from: date_from))
    |> Enum.group_by(& &1.date)
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
  end

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, workspace_id) do
    where(query, [f], f.workspace_id == ^workspace_id)
  end

  defp maybe_filter_memory_type(query, nil), do: query
  defp maybe_filter_memory_type(query, ""), do: query

  defp maybe_filter_memory_type(query, type) do
    where(query, [e], e.memory_type == ^type)
  end

  defp maybe_filter_date_from(query, nil), do: query

  defp maybe_filter_date_from(query, %Date{} = date) do
    where(query, [e], e.date >= ^date)
  end

  defp maybe_filter_date_from(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> maybe_filter_date_from(query, date)
      _ -> query
    end
  end

  defp maybe_filter_date_to(query, nil), do: query

  defp maybe_filter_date_to(query, %Date{} = date) do
    where(query, [e], e.date <= ^date)
  end

  defp maybe_filter_date_to(query, date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> maybe_filter_date_to(query, date)
      _ -> query
    end
  end

  defp maybe_filter_query(query, nil), do: query
  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, search) do
    pattern = "%#{search}%"
    where(query, [e], ilike(e.content, ^pattern))
  end
end
