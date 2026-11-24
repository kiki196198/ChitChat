defmodule ChatApp.Repo.Migrations.CreateSessionsAndUserProfiles do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :username, :citext, null: false
      add :display_name, :string, null: false
      add :avatar_url, :text
      add :deleted_at, :utc_datetime
    end

    create unique_index(:users, [:username])
    create index(:users, [:deleted_at])

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :user_agent, :text
      add :authenticated_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:user_id])
    create index(:sessions, [:expires_at])
  end
end
