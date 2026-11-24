defmodule ChatApp.Accounts do
  @moduledoc "Account profiles and revocable browser sessions."

  import Ecto.Query, warn: false
  alias ChatApp.Repo
  alias ChatApp.Accounts.{Session, User}

  def get_user!(id), do: Repo.get!(User, id)

  def get_or_create_google_user(claims) when is_map(claims) do
    uid = claims["sub"]
    email = claims["email"] |> String.trim() |> String.downcase()

    case Repo.get_by(User, firebase_uid: uid) do
      %User{} = user ->
        {:ok, user}

      nil ->
        if Repo.get_by(User, email: email) do
          {:error, :email_already_registered}
        else
          local_part = email |> String.split("@", parts: 2) |> List.first()

          base =
            local_part
            |> String.downcase()
            |> String.replace(~r/[^a-z0-9_]/, "_")
            |> String.slice(0, 20)

          base = if String.length(base) >= 3, do: base, else: "member"
          suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
          display_name = claims["name"] || local_part

          %User{}
          |> User.firebase_changeset(%{
            email: email,
            firebase_uid: uid,
            username: "#{base}_#{suffix}",
            display_name: String.slice(display_name, 0, 60),
            avatar_url: claims["picture"]
          })
          |> Repo.insert()
        end
    end
  end

  def change_user_profile(user, attrs \\ %{}), do: User.profile_changeset(user, attrs)

  def update_user_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  def generate_user_session_token(user, opts \\ []) do
    token = :crypto.strong_rand_bytes(32)
    now = DateTime.utc_now(:second)
    session_id = Keyword.get(opts, :session_id, Ecto.UUID.generate())

    %Session{
      id: session_id,
      user_id: user.id,
      token_hash: :crypto.hash(:sha256, token),
      user_agent: opts |> Keyword.get(:user_agent) |> normalize_user_agent(),
      authenticated_at: now,
      last_seen_at: now,
      expires_at: DateTime.add(now, 14, :day)
    }
    |> Repo.insert!()

    token
  end

  def get_user_by_session_token(token) when is_binary(token) do
    token_hash = :crypto.hash(:sha256, token)
    now = DateTime.utc_now(:second)

    query =
      from session in Session,
        join: user in assoc(session, :user),
        where: session.token_hash == ^token_hash and session.expires_at > ^now,
        select:
          {%{user | authenticated_at: session.authenticated_at, session_id: session.id}, session}

    case Repo.one(query) do
      {%User{} = user, %Session{} = session} ->
        if DateTime.diff(now, session.last_seen_at, :second) >= 60 do
          Repo.update_all(from(s in Session, where: s.id == ^session.id),
            set: [last_seen_at: now]
          )
        end

        {user, session.inserted_at}

      nil ->
        nil
    end
  end

  def get_user_by_session_token(_), do: nil

  def delete_user_session_token(token) do
    token_hash = :crypto.hash(:sha256, token)
    Repo.delete_all(from(Session, where: [token_hash: ^token_hash]))
    :ok
  end

  defp normalize_user_agent(nil), do: nil
  defp normalize_user_agent(user_agent), do: String.slice(user_agent, 0, 500)
end
