defmodule ChatApp.Accounts.Session do
  @moduledoc "A revocable authenticated browser session."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sessions" do
    field :token_hash, :binary, redact: true
    field :user_agent, :string
    field :authenticated_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :user, ChatApp.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
