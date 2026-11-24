defmodule ChatApp.Blocking do
  @moduledoc "User blocking relationships and private-chat interaction checks."

  import Ecto.Query

  alias ChatApp.Accounts.{Block, Scope, User}
  alias ChatApp.Repo

  def status(%Scope{user: %User{id: user_id}}, other_user_id) do
    with {:ok, other_user_id} <- Ecto.UUID.cast(other_user_id),
         true <- other_user_id != user_id do
      %{
        blocked_by_me?: blocked_by?(user_id, other_user_id),
        blocked_me?: blocked_by?(other_user_id, user_id)
      }
    else
      _ -> %{blocked_by_me?: false, blocked_me?: false}
    end
  end

  def status(_scope, _other_user_id),
    do: %{blocked_by_me?: false, blocked_me?: false}

  def blocked_between?(user_a_id, user_b_id) do
    with {:ok, user_a_id} <- Ecto.UUID.cast(user_a_id),
         {:ok, user_b_id} <- Ecto.UUID.cast(user_b_id),
         true <- user_a_id != user_b_id do
      Repo.exists?(
        from block in Block,
          where:
            (block.blocker_id == ^user_a_id and block.blocked_id == ^user_b_id) or
              (block.blocker_id == ^user_b_id and block.blocked_id == ^user_a_id)
      )
    else
      _ -> false
    end
  end

  def block(%Scope{user: %User{id: blocker_id}}, blocked_user_id) do
    with {:ok, blocked_user_id} <- Ecto.UUID.cast(blocked_user_id),
         true <- blocked_user_id != blocker_id,
         %User{deleted_at: nil} <- Repo.get(User, blocked_user_id),
         changeset <-
           Block.changeset(%Block{}, %{
             blocker_id: blocker_id,
             blocked_id: blocked_user_id
           }),
         {:ok, _} <-
           Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:blocker_id, :blocked_id]
           ) do
      broadcast_relationship_change(blocker_id, blocked_user_id)
      :ok
    else
      false -> {:error, :cannot_block_self}
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def block(_scope, _blocked_user_id), do: {:error, :not_found}

  def unblock(%Scope{user: %User{id: blocker_id}}, blocked_user_id) do
    with {:ok, blocked_user_id} <- Ecto.UUID.cast(blocked_user_id) do
      Repo.delete_all(
        from block in Block,
          where: block.blocker_id == ^blocker_id and block.blocked_id == ^blocked_user_id
      )

      broadcast_relationship_change(blocker_id, blocked_user_id)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  def unblock(_scope, _blocked_user_id), do: {:error, :not_found}

  defp blocked_by?(blocker_id, blocked_id) do
    Repo.exists?(
      from block in Block,
        where: block.blocker_id == ^blocker_id and block.blocked_id == ^blocked_id
    )
  end

  defp broadcast_relationship_change(user_a_id, user_b_id) do
    Phoenix.PubSub.broadcast(
      ChatApp.PubSub,
      "user:#{user_a_id}",
      {:relationship_changed, user_b_id}
    )

    Phoenix.PubSub.broadcast(
      ChatApp.PubSub,
      "user:#{user_b_id}",
      {:relationship_changed, user_a_id}
    )
  end
end
