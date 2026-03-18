defmodule Platform.Artifacts.StoreTest do
  use ExUnit.Case, async: false

  alias Platform.Artifacts

  defmodule SuccessfulDestination do
    @behaviour Platform.Artifacts.Destination

    @impl true
    def destination_key(opts) do
      Keyword.get(opts, :destination, "tasky://thread")
    end

    @impl true
    def publish(_artifact, attempt, opts) do
      {:ok,
       %{
         attempt_id: attempt.id,
         status: :succeeded,
         external_ref: Keyword.get(opts, :external_ref, "published-123"),
         metadata: %{published_by: "test"}
       }}
    end
  end

  defmodule FailingDestination do
    @behaviour Platform.Artifacts.Destination

    @impl true
    def destination_key(_opts), do: "tasky://canvas"

    @impl true
    def publish(_artifact, _attempt, _opts), do: {:error, :destination_down}
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp artifact_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: unique_id("artifact"),
        kind: :task_output,
        substrate: :file,
        producer: %{type: :execution_run, id: unique_id("run")},
        scope: %{task_id: unique_id("task"), run_id: unique_id("run")},
        locator: %{path: "/tmp/output.txt"},
        metadata: %{label: "task output"}
      },
      overrides
    )
  end

  defp attempt_attrs(artifact_id, overrides \\ %{}) do
    Map.merge(
      %{
        id: unique_id("attempt"),
        artifact_id: artifact_id,
        destination: "tasky://thread",
        requested_by: "run-server",
        metadata: %{channel: "chat"}
      },
      overrides
    )
  end

  describe "register/fetch/list" do
    test "stores execution and chat artifacts through one contract" do
      {:ok, task_output} = Artifacts.register(artifact_attrs())

      {:ok, chat_attachment} =
        Artifacts.register(
          artifact_attrs(%{
            id: unique_id("artifact"),
            kind: :chat_attachment,
            substrate: :uri,
            producer: %{type: :chat_message, id: unique_id("message")},
            scope: %{task_id: task_output.scope.task_id, thread_id: unique_id("thread")},
            locator: %{url: "https://example.test/artifact"}
          })
        )

      assert {:ok, ^task_output} = Artifacts.fetch(task_output.id)

      assert [^chat_attachment] =
               Artifacts.list(kind: :chat_attachment, scope_task_id: task_output.scope.task_id)
    end
  end

  describe "publication attempts and results" do
    test "records publication separately from artifact registration" do
      {:ok, artifact} = Artifacts.register(artifact_attrs())
      {:ok, attempt} = Artifacts.record_attempt(attempt_attrs(artifact.id))

      assert attempt.status == :pending
      assert [^attempt] = Artifacts.list_attempts(artifact.id)

      {:ok, result} =
        Artifacts.record_result(%{
          attempt_id: attempt.id,
          artifact_id: artifact.id,
          destination: attempt.destination,
          status: :succeeded,
          external_ref: "thread-msg-123",
          metadata: %{published_at_version: 1}
        })

      assert {:ok, stored_attempt} = Artifacts.fetch_attempt(attempt.id)
      assert stored_attempt.status == :succeeded
      assert {:ok, ^result} = Artifacts.fetch_result(attempt.id)
    end

    test "rejects attempts and results that do not match existing records" do
      assert {:error, :artifact_not_found} =
               Artifacts.record_attempt(attempt_attrs("missing-artifact"))

      {:ok, artifact} = Artifacts.register(artifact_attrs())
      {:ok, attempt} = Artifacts.record_attempt(attempt_attrs(artifact.id))

      assert {:error, :destination_mismatch} =
               Artifacts.record_result(%{
                 attempt_id: attempt.id,
                 artifact_id: artifact.id,
                 destination: "tasky://canvas",
                 status: :failed,
                 error: %{message: "wrong target"}
               })
    end
  end

  describe "publish/3" do
    test "records publication attempts and successful results through one contract" do
      {:ok, artifact} = Artifacts.register(artifact_attrs())

      assert {:ok, publication} =
               Artifacts.publish(artifact, SuccessfulDestination,
                 destination: "tasky://thread",
                 external_ref: "thread-msg-456",
                 requested_by: "task-runner",
                 attempt_metadata: %{surface: "chat"}
               )

      assert publication.artifact.id == artifact.id
      assert publication.attempt.destination == "tasky://thread"
      assert publication.attempt.requested_by == "task-runner"
      assert publication.result.status == :succeeded
      assert publication.result.external_ref == "thread-msg-456"
      assert {:ok, stored_attempt} = Artifacts.fetch_attempt(publication.attempt.id)
      assert stored_attempt.status == :succeeded
      assert {:ok, stored_result} = Artifacts.fetch_result(publication.attempt.id)
      assert stored_result.metadata == %{published_by: "test"}
    end

    test "records failed publication results without mutating the artifact" do
      {:ok, artifact} = Artifacts.register(artifact_attrs())

      assert {:error, :destination_down, publication} =
               Artifacts.publish(artifact.id, FailingDestination, requested_by: "canvas-sync")

      assert publication.artifact.id == artifact.id
      assert publication.attempt.destination == "tasky://canvas"
      assert publication.result.status == :failed
      assert publication.result.error == %{message: ":destination_down"}
      assert {:ok, ^artifact} = Artifacts.fetch(artifact.id)
    end
  end
end
