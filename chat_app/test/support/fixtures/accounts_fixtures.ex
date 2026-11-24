defmodule ChatApp.AccountsFixtures do
  @moduledoc "Test helpers for Firebase-backed profiles and browser sessions."

  import Ecto.Query

  alias ChatApp.Accounts
  alias ChatApp.Accounts.{Scope, Session}
  alias ChatApp.Repo

  def unique_user_email, do: "user-#{Ecto.UUID.generate()}@example.com"
  def valid_user_password, do: "unused-after-firebase-auth"

  def valid_user_attributes(attrs \\ %{}) do
    Map.merge(
      %{
        email: unique_user_email(),
        firebase_uid: Ecto.UUID.generate(),
        display_name: "Test User"
      },
      attrs
    )
  end

  def unconfirmed_user_fixture(attrs \\ %{}), do: user_fixture(attrs)

  def user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)

    claims = %{
      "sub" => field(attrs, :firebase_uid),
      "email" => field(attrs, :email),
      "email_verified" => true,
      "name" => field(attrs, :display_name),
      "picture" => field(attrs, :avatar_url)
    }

    {:ok, user} = Accounts.get_or_create_google_user(claims)

    profile_attrs =
      %{}
      |> maybe_put(:username, field(attrs, :username))
      |> maybe_put(:display_name, field(attrs, :display_name))
      |> maybe_put(:avatar_url, field(attrs, :avatar_url))

    if map_size(profile_attrs) > 0 do
      {:ok, user} = Accounts.update_user_profile(user, profile_attrs)
      user
    else
      user
    end
  end

  def user_scope_fixture, do: user_fixture() |> user_scope_fixture()
  def user_scope_fixture(user), do: Scope.for_user(user)

  # Kept so old generated test modules compile while their password assertions
  # are being replaced. Firebase Authentication owns credentials now.
  def set_password(user), do: user

  def extract_user_token(_fun),
    do: raise("Email-token authentication was removed in favor of Firebase.")

  def generate_user_magic_link_token(_user),
    do: raise("Magic-link authentication was removed in favor of Firebase.")

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    token_hash = :crypto.hash(:sha256, token)

    Repo.update_all(
      from(session in Session, where: session.token_hash == ^token_hash),
      set: [authenticated_at: authenticated_at]
    )
  end

  def offset_user_token(token, amount_to_add, unit) do
    token_hash = :crypto.hash(:sha256, token)
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Repo.update_all(
      from(session in Session, where: session.token_hash == ^token_hash),
      set: [inserted_at: dt]
    )
  end

  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
