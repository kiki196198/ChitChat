defmodule ChatApp.Repo.Migrations.CreateRoomsAndMemberships do
  use Ecto.Migration

  def change do
    create table(:rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :name, :string
      add :created_by, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :user_low_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :user_high_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:rooms, :rooms_type_check, check: "type IN ('private', 'group')")

    create constraint(:rooms, :rooms_shape_check,
             check: """
             (type = 'private' AND name IS NULL AND user_low_id IS NOT NULL AND
              user_high_id IS NOT NULL AND user_low_id < user_high_id AND
              (created_by = user_low_id OR created_by = user_high_id)) OR
             (type = 'group' AND name IS NOT NULL AND length(trim(name)) > 0 AND
              user_low_id IS NULL AND user_high_id IS NULL)
             """
           )

    create index(:rooms, [:created_by])

    create unique_index(:rooms, [:user_low_id, :user_high_id],
             where: "type = 'private'",
             name: :rooms_private_pair_index
           )

    create table(:room_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :role, :string, null: false
      add :joined_at, :utc_datetime, null: false
      add :left_at, :utc_datetime
      add :last_delivered_seq, :bigint, null: false, default: 0
      add :last_read_seq, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create constraint(:room_members, :room_members_role_check,
             check: "role IN ('owner', 'admin', 'member')"
           )

    create constraint(:room_members, :room_members_cursor_check,
             check: "last_read_seq >= 0 AND last_delivered_seq >= last_read_seq"
           )

    create constraint(:room_members, :room_members_period_check,
             check: "left_at IS NULL OR left_at > joined_at"
           )

    create unique_index(:room_members, [:room_id, :user_id],
             where: "left_at IS NULL",
             name: :room_members_one_active_membership
           )

    create index(:room_members, [:user_id, :room_id])
    create index(:room_members, [:room_id])
  end
end
