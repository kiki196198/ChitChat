defmodule ChatApp.Rooms.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rooms" do
    field :type, :string
    field :name, :string
    field :deleted_at, :utc_datetime

    belongs_to :creator, ChatApp.Accounts.User, foreign_key: :created_by
    belongs_to :user_low, ChatApp.Accounts.User
    belongs_to :user_high, ChatApp.Accounts.User
    has_many :members, ChatApp.Rooms.RoomMember

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:type, :name])
    |> validate_inclusion(:type, ["private", "group"])
    |> validate_group_name()
  end

  defp validate_group_name(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_group_name(changeset) do
    if get_field(changeset, :type) == "group" do
      changeset
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 120)
    else
      changeset
    end
  end
end
