defmodule ChatApp.Repo.Migrations.ReplacePasswordAuthWithFirebaseGoogle do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :firebase_uid, :string
      remove :hashed_password
      remove :confirmed_at
    end

    create unique_index(:users, [:firebase_uid])
    drop_if_exists table(:users_tokens)
  end
end
