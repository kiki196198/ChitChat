defmodule ChatApp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "users" do
    field :email, :string
    field :firebase_uid, :string
    field :username, :string
    field :display_name, :string
    field :avatar_url, :string
    field :deleted_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :session_id, :binary_id, virtual: true

    has_many :sessions, ChatApp.Accounts.Session

    timestamps(type: :utc_datetime)
  end

  def firebase_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :firebase_uid, :username, :display_name, :avatar_url])
    |> update_change(:email, &String.downcase(String.trim(&1)))
    |> update_change(:username, &String.downcase(String.trim(&1)))
    |> validate_required([:email, :firebase_uid, :username, :display_name])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
    |> validate_format(:username, ~r/^[a-z0-9_]{3,32}$/)
    |> validate_length(:display_name, min: 2, max: 60)
    |> validate_length(:avatar_url, max: 2048)
    |> unique_constraint(:firebase_uid)
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :avatar_url])
    |> update_change(:username, &String.downcase(String.trim(&1)))
    |> validate_required([:username, :display_name])
    |> validate_format(:username, ~r/^[a-z0-9_]{3,32}$/)
    |> validate_length(:display_name, min: 2, max: 60)
    |> validate_length(:avatar_url, max: 2048)
    |> unsafe_validate_unique(:username, ChatApp.Repo)
    |> unique_constraint(:username)
  end
end
