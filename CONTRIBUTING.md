# Contributing

## Local setup (macOS, Homebrew)

Install Elixir, Erlang (pulled in by Elixir), and PostgreSQL 16:

```bash
brew install elixir postgresql@16
brew services start postgresql@16
```

The Phoenix dev/test config in `apps/platform/config/{dev,test}.exs` defaults to `PGUSER=postgres` / `PGPASSWORD=postgres`. Homebrew's PostgreSQL initializes with your macOS username as the default superuser and no `postgres` role, so create one:

```bash
psql postgres -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';"
```

Then install Elixir toolchain bits and project deps:

```bash
cd apps/platform
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get
```

## Running checks

Match what CI runs (`.github/workflows/ci.yml`):

```bash
cd apps/platform
mix format --check-formatted
mix ecto.create
mix ecto.migrate
mix test
```

The full-suite test run auto-creates and migrates the test database on each invocation.

For a fuller local-only check, the repo also supports `mix precommit` (compile with warnings-as-errors, unused-dep check, format, test). CI does not gate on warnings-as-errors, so pre-existing warnings may block precommit even when CI is green.

## Overriding DB defaults

If you already have a Postgres instance and don't want a separate `postgres` role, export the credentials before running mix:

```bash
PGUSER=$USER PGPASSWORD='' mix test
```

`config/test.exs` reads `PGUSER`, `PGPASSWORD`, `PGHOST`, and `PGPORT` via `System.get_env/2`.

## More

See `CLAUDE.md` for architecture, domain-context boundaries, Elixir/Phoenix idioms, and the ADR index under `docs/decisions/`.
