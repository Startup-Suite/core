defmodule Platform.MixProject do
  use Mix.Project

  def project do
    [
      app: :platform,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Platform.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssl, :inets]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:assent, "~> 0.2"},
      {:ssl_verify_fun, "~> 1.1"},
      {:certifi, "~> 2.4"},
      {:mint, "~> 1.0"},
      {:castore, "~> 1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ecto_sql, "~> 3.10"},
      {:cloak_ecto, "~> 1.3"},
      {:req, "~> 0.5"},
      {:postgrex, ">= 0.0.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:oauth2, "~> 2.1"},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", &ensure_local_postgres/1, "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": [&ensure_local_postgres/1, "ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind platform", "esbuild platform"],
      "assets.deploy": [
        "tailwind platform --minify",
        "esbuild platform --minify",
        "phx.digest"
      ],
      test: [&ensure_local_postgres/1, "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp ensure_local_postgres(_args) do
    if Mix.env() in [:dev, :test] and local_pg_target?() and not postgres_reachable?() do
      ensure_docker_postgres!()
      wait_for_postgres!()
    end

    :ok
  end

  defp local_pg_target? do
    case database_host() do
      host when host in ["localhost", "127.0.0.1", nil, ""] -> true
      _ -> false
    end
  end

  defp database_host do
    case System.get_env("DATABASE_URL") do
      nil -> System.get_env("PGHOST", "localhost")
      "" -> System.get_env("PGHOST", "localhost")
      url -> URI.parse(url).host || "localhost"
    end
  end

  defp database_port do
    case System.get_env("DATABASE_URL") do
      nil -> String.to_integer(System.get_env("PGPORT", "5432"))
      "" -> String.to_integer(System.get_env("PGPORT", "5432"))
      url -> URI.parse(url).port || 5432
    end
  end

  defp postgres_reachable? do
    host = String.to_charlist(database_host() || "localhost")

    case :gen_tcp.connect(host, database_port(), [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp ensure_docker_postgres! do
    container = postgres_container_name()

    {running, 0} =
      System.cmd("docker", ["ps", "--filter", "name=^/#{container}$", "--format", "{{.Names}}"],
        stderr_to_stdout: true
      )

    cond do
      String.trim(running) == container ->
        :ok

      container_exists?(container) ->
        run_docker!("start existing postgres container", ["start", container])

      true ->
        run_docker!("start postgres container", [
          "run",
          "--detach",
          "--name",
          container,
          "--env",
          "POSTGRES_USER=#{System.get_env("PGUSER", "postgres")}",
          "--env",
          "POSTGRES_PASSWORD=#{System.get_env("PGPASSWORD", "postgres")}",
          "--publish",
          "#{database_port()}:5432",
          "postgres:16-alpine"
        ])
    end
  end

  defp container_exists?(container) do
    case System.cmd(
           "docker",
           ["ps", "-a", "--filter", "name=^/#{container}$", "--format", "{{.Names}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) == container
      _ -> false
    end
  end

  defp run_docker!(context, args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        Mix.raise("failed to #{context}: #{String.trim(output)}")
    end
  end

  defp wait_for_postgres!(attempts_left \\ 60)

  defp wait_for_postgres!(0) do
    Mix.raise("PostgreSQL did not become ready at #{database_host()}:#{database_port()} in time")
  end

  defp wait_for_postgres!(attempts_left) do
    if postgres_reachable?() and postgres_accepting_commands?() do
      :ok
    else
      Process.sleep(500)
      wait_for_postgres!(attempts_left - 1)
    end
  end

  defp postgres_accepting_commands? do
    container = postgres_container_name()

    if container_exists?(container) do
      case System.cmd(
             "docker",
             [
               "exec",
               container,
               "pg_isready",
               "-U",
               System.get_env("PGUSER", "postgres"),
               "-d",
               "postgres"
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> true
        _ -> false
      end
    else
      postgres_reachable?()
    end
  end

  defp postgres_container_name do
    System.get_env("PLATFORM_POSTGRES_CONTAINER", "platform-local-postgres")
  end
end
