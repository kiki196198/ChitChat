defmodule ChatApp.Repo.Migrations.CreateUserBlocks do
  use Ecto.Migration

  def change do
    create table(:user_blocks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :blocker_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :blocked_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:user_blocks, :user_blocks_not_self_check,
             check: "blocker_id <> blocked_id"
           )

    create unique_index(:user_blocks, [:blocker_id, :blocked_id], name: :user_blocks_pair_index)
    create index(:user_blocks, [:blocked_id, :blocker_id])
  end
end
