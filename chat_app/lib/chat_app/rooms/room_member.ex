defmodule ChatApp.Rooms.RoomMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_members" do
    field :role, :string
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime
    field :last_delivered_seq, :integer, default: 0
    field :last_read_seq, :integer, default: 0

    belongs_to :room, ChatApp.Rooms.Room
    belongs_to :user, ChatApp.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:role, :joined_at, :left_at, :last_delivered_seq, :last_read_seq])
    |> validate_required([:role, :joined_at, :last_delivered_seq, :last_read_seq])
    |> validate_inclusion(:role, ["owner", "admin", "member"])
    |> validate_number(:last_delivered_seq, greater_than_or_equal_to: 0)
    |> validate_number(:last_read_seq, greater_than_or_equal_to: 0)
    |> validate_read_cursor()
    |> check_constraint(:left_at, name: :room_members_period_check)
    |> unique_constraint([:room_id, :user_id], name: :room_members_one_active_membership)
  end

  defp validate_read_cursor(changeset) do
    if (get_field(changeset, :last_read_seq) || 0) >
         (get_field(changeset, :last_delivered_seq) || 0) do
      add_error(changeset, :last_read_seq, "cannot exceed the delivered sequence")
    else
      changeset
    end
  end
end
