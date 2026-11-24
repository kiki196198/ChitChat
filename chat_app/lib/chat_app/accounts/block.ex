defmodule ChatApp.Accounts.Block do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_blocks" do
    belongs_to :blocker, ChatApp.Accounts.User
    belongs_to :blocked, ChatApp.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(block, attrs) do
    block
    |> cast(attrs, [:blocker_id, :blocked_id])
    |> validate_required([:blocker_id, :blocked_id])
    |> check_constraint(:blocked_id, name: :user_blocks_not_self_check)
    |> unique_constraint([:blocker_id, :blocked_id], name: :user_blocks_pair_index)
  end
end
