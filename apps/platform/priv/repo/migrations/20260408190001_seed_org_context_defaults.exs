defmodule Platform.Repo.Migrations.SeedOrgContextDefaults do
  use Ecto.Migration

  def up do
    # Flush ensures the tables from the previous migration exist
    flush()
    Platform.Org.ContextSeeder.seed_defaults(nil)
  end

  def down do
    # No-op: we don't remove seeded data on rollback
    :ok
  end
end
