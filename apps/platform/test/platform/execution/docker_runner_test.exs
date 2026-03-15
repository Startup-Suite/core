defmodule Platform.Execution.DockerRunnerTest do
  use ExUnit.Case, async: false

  alias Platform.Execution.{CredentialLease, DockerRunner, Run}

  defmodule FakeSuiteRunnerdClient do
    @behaviour Platform.Execution.SuiteRunnerdClient

    alias Platform.Execution.Run

    @impl true
    def spawn_run(%Run{} = run, payload, opts) do
      send(opts[:test_pid], {:spawn_run, run, payload})

      {:ok,
       %{
         container_id: "ctr-#{run.id}",
         status: :starting,
         image: "suite-runner:dev"
       }}
    end

    @impl true
    def describe_run(%Run{} = run, provider_ref, opts) do
      send(opts[:test_pid], {:describe_run, run, provider_ref})

      {:ok,
       %{
         status: :running,
         exit_code: nil,
         stop_mode: nil,
         image: provider_ref[:image] || "suite-runner:dev"
       }}
    end

    @impl true
    def request_stop(%Run{} = run, provider_ref, opts) do
      send(opts[:test_pid], {:request_stop, run, provider_ref})
      :ok
    end

    @impl true
    def force_stop(%Run{} = run, provider_ref, opts) do
      send(opts[:test_pid], {:force_stop, run, provider_ref})
      :ok
    end
  end

  describe "spawn_run/2" do
    test "delegates to suite-runnerd with workspace + leased env payload" do
      run = run_fixture("docker-run")
      root = temp_dir("docker-root")

      {:ok, lease} =
        CredentialLease.lease(:github,
          run_id: run.id,
          github_token: "gh-test-token",
          author_name: "Zip",
          author_email: "zip@test.local"
        )

      assert {:ok, ref} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: root,
                 command: "/bin/sh",
                 args: ["-c", "echo hello"],
                 credential_lease: lease,
                 meta_overrides: [runner_image: "suite-runner:dev"]
               )

      assert_receive {:spawn_run, ^run, payload}
      assert payload.workspace_root == Path.expand(root)
      assert payload.workspace_path == Path.join(Path.expand(root), run.id)
      assert payload.command == "/bin/sh"
      assert payload.args == ["-c", "echo hello"]
      assert payload.env["GITHUB_TOKEN"] == "gh-test-token"
      assert payload.meta["runner_image"] == nil
      assert payload.meta[:runner_image] == "suite-runner:dev"

      assert ref.provider == :docker
      assert ref.run_id == run.id
      assert ref.workspace_root == Path.expand(root)
      assert ref.workspace_path == Path.join(Path.expand(root), run.id)
      assert ref.container_id == "ctr-#{run.id}"
      assert ref.image == "suite-runner:dev"
    end

    test "returns error when command is missing" do
      run = run_fixture("docker-run-no-command")

      assert {:error, :missing_command} =
               DockerRunner.spawn_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()],
                 run_root: temp_dir("docker-root")
               )
    end
  end

  describe "request_stop/2 and force_stop/2" do
    test "delegates stop/kill using the existing provider ref on the run" do
      run =
        run_fixture("docker-run-stop")
        |> Map.put(:runner_ref, %{
          provider: :docker,
          run_id: "docker-run-stop",
          workspace_root: "/tmp/root",
          workspace_path: "/tmp/root/docker-run-stop",
          container_id: "ctr-docker-run-stop"
        })

      assert :ok =
               DockerRunner.request_stop(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )

      assert_receive {:request_stop, ^run, %{container_id: "ctr-docker-run-stop"}}

      assert :ok =
               DockerRunner.force_stop(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )

      assert_receive {:force_stop, ^run, %{container_id: "ctr-docker-run-stop"}}
    end
  end

  describe "describe_run/2" do
    test "merges suite-runnerd status with the stored provider ref" do
      run =
        run_fixture("docker-run-describe")
        |> Map.put(:runner_ref, %{
          provider: :docker,
          run_id: "docker-run-describe",
          workspace_root: "/tmp/root",
          workspace_path: "/tmp/root/docker-run-describe",
          container_id: "ctr-docker-run-describe",
          image: "suite-runner:dev"
        })

      assert {:ok, description} =
               DockerRunner.describe_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )

      assert_receive {:describe_run, ^run, %{container_id: "ctr-docker-run-describe"}}

      assert description.provider == :docker
      assert description.status == :running
      assert description.container_id == "ctr-docker-run-describe"
      assert description.image == "suite-runner:dev"
      assert Map.has_key?(description, :workspace_path)
    end

    test "returns error when provider ref is missing" do
      run = run_fixture("docker-run-missing-ref")

      assert {:error, :missing_provider_ref} =
               DockerRunner.describe_run(run,
                 client: FakeSuiteRunnerdClient,
                 client_opts: [test_pid: self()]
               )
    end
  end

  defp run_fixture(run_id) do
    %Run{
      id: run_id,
      task_id: "task-#{run_id}",
      runner_type: :docker,
      meta: %{}
    }
  end

  defp temp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
