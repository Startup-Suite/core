defmodule PlatformWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub webhook events and processes them.

  Handles:
  - `pull_request` events with `action: "closed"` + `merged: true` → changelog entries
  - `check_suite.completed` → auto-evaluate `ci_passed` validations via PlanEngine
  - `workflow_run.completed` → auto-evaluate `ci_passed` validations via PlanEngine

  HMAC signature verification is performed when a project-level webhook secret
  is configured in `project.deploy_config["webhook_secret"]`.
  """

  use PlatformWeb, :controller

  import Ecto.Query

  alias Platform.Changelog
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PlanEngine, Plan, Stage, Task, Validation}

  require Logger

  # ── Plugs ────────────────────────────────────────────────────────────────

  plug :verify_signature when action in [:handle]

  # ── Handlers ─────────────────────────────────────────────────────────────

  @doc """
  Handle merged pull request events → create changelog entries.
  """
  def handle(conn, %{"action" => "closed", "pull_request" => pr} = _params) do
    if pr["merged"] do
      process_merged_pr(conn, pr)
    else
      conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not merged"})
    end
  end

  @doc """
  Handle check_suite.completed events → evaluate ci_passed validations.
  """
  def handle(conn, %{"action" => "completed", "check_suite" => check_suite} = _params) do
    branch = check_suite["head_branch"]
    conclusion = check_suite["conclusion"]
    sha = get_in(check_suite, ["head_sha"])
    run_url = get_in(check_suite, ["url"])

    process_ci_event(conn, branch, conclusion, sha, run_url, "check_suite")
  end

  @doc """
  Handle workflow_run.completed events → evaluate ci_passed validations.
  """
  def handle(conn, %{"action" => "completed", "workflow_run" => workflow_run} = _params) do
    branch = workflow_run["head_branch"]
    conclusion = workflow_run["conclusion"]
    sha = get_in(workflow_run, ["head_sha"])
    run_url = get_in(workflow_run, ["html_url"])

    process_ci_event(conn, branch, conclusion, sha, run_url, "workflow_run")
  end

  def handle(conn, _params) do
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not a relevant event"})
  end

  # ── CI event processing ─────────────────────────────────────────────────

  defp process_ci_event(conn, branch, conclusion, sha, run_url, event_type) do
    task_id = Changelog.extract_task_id_from_branch(branch)

    if task_id do
      case find_pending_ci_validation(task_id) do
        nil ->
          Logger.debug(
            "[Webhook] No pending ci_passed validation for task #{task_id} (branch: #{branch})"
          )

          conn
          |> put_status(:ok)
          |> json(%{status: "ignored", reason: "no pending ci_passed validation"})

        validation ->
          status = if conclusion == "success", do: "passed", else: "failed"

          evidence = %{
            "event_type" => event_type,
            "conclusion" => conclusion,
            "sha" => sha,
            "run_url" => run_url,
            "branch" => branch,
            "evaluated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }

          case PlanEngine.evaluate_validation(validation.id, %{
                 status: status,
                 evidence: evidence,
                 evaluated_by: "github_webhook"
               }) do
            {:ok, updated} ->
              Logger.info(
                "[Webhook] Evaluated ci_passed validation #{updated.id} as #{status} " <>
                  "for task #{task_id} (#{event_type}, conclusion: #{conclusion})"
              )

              conn
              |> put_status(:created)
              |> json(%{
                status: "evaluated",
                validation_id: updated.id,
                result: status
              })

            {:error, reason} ->
              Logger.warning(
                "[Webhook] Failed to evaluate ci_passed validation: #{inspect(reason)}"
              )

              conn
              |> put_status(:unprocessable_entity)
              |> json(%{status: "error", reason: inspect(reason)})
          end
      end
    else
      conn
      |> put_status(:ok)
      |> json(%{status: "ignored", reason: "branch does not match task pattern"})
    end
  end

  @doc false
  def find_pending_ci_validation(task_id) do
    query =
      from(v in Validation,
        join: s in Stage,
        on: s.id == v.stage_id,
        join: p in Plan,
        on: p.id == s.plan_id,
        join: t in Task,
        on: t.id == p.task_id,
        where: t.id == ^task_id,
        where: p.status in ~w(approved),
        where: s.status == "running",
        where: v.kind == "ci_passed",
        where: v.status == "pending",
        order_by: [asc: s.position],
        limit: 1
      )

    Repo.one(query)
  end

  # ── Merged PR processing (changelog) ────────────────────────────────────

  defp process_merged_pr(conn, pr) do
    raw_title = pr["title"] || ""
    {cleaned_title, tags} = Changelog.parse_title(raw_title)

    branch = get_in(pr, ["head", "ref"])
    body = pr["body"]

    task_id =
      Changelog.extract_task_id_from_branch(branch) ||
        Changelog.extract_task_id_from_body(body)

    merged_at = parse_datetime(pr["merged_at"])

    description =
      case body do
        body when is_binary(body) and byte_size(body) > 0 ->
          body |> String.slice(0, 500) |> String.trim()

        _ ->
          nil
      end

    attrs = %{
      title: cleaned_title,
      description: description,
      pr_number: pr["number"],
      pr_url: pr["html_url"],
      commit_sha: pr["merge_commit_sha"],
      author: get_in(pr, ["user", "login"]),
      task_id: task_id,
      tags: tags,
      merged_at: merged_at
    }

    case Changelog.create_entry(attrs) do
      {:ok, entry} ->
        Logger.info("[Changelog] Created entry for PR ##{entry.pr_number}: #{entry.title}")
        conn |> put_status(:created) |> json(%{status: "created", id: entry.id})

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        Logger.warning("[Changelog] Failed to create entry: #{inspect(errors)}")
        conn |> put_status(:unprocessable_entity) |> json(%{status: "error", errors: errors})
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # ── HMAC signature verification ─────────────────────────────────────────

  @doc false
  defp verify_signature(conn, _opts) do
    # We need the raw body for HMAC verification.
    # If no signature header is present, skip verification (backward compat).
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()

    if signature do
      raw_body = conn.assigns[:raw_body] || read_raw_body(conn)

      # Try to find the webhook secret from the request context.
      # The repo URL in the payload maps to a project's webhook_secret.
      repo_url = extract_repo_url(conn.params)
      secret = lookup_webhook_secret(repo_url)

      cond do
        is_nil(secret) ->
          # No secret configured for this project — skip verification
          conn

        verify_hmac(raw_body, signature, secret) ->
          conn

        true ->
          Logger.warning("[Webhook] HMAC signature mismatch for repo: #{repo_url}")

          conn
          |> put_status(:unauthorized)
          |> json(%{status: "error", reason: "signature mismatch"})
          |> halt()
      end
    else
      # No signature header — backward compat, allow through
      conn
    end
  end

  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp extract_repo_url(params) do
    get_in(params, ["repository", "html_url"])
  end

  defp lookup_webhook_secret(nil), do: nil

  defp lookup_webhook_secret(repo_url) do
    alias Platform.Tasks.Project

    project =
      Project
      |> where([p], p.repo_url == ^repo_url)
      |> limit(1)
      |> Repo.one()

    case project do
      %{deploy_config: %{"webhook_secret" => secret}} when is_binary(secret) and secret != "" ->
        secret

      _ ->
        nil
    end
  end

  @doc false
  def verify_hmac(body, signature, secret) do
    # signature format: "sha256=<hex>"
    case String.split(signature, "=", parts: 2) do
      ["sha256", hex_digest] ->
        computed = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(computed, String.downcase(hex_digest))

      _ ->
        false
    end
  end
end
