defmodule ChatApp.Rooms do
  @moduledoc "Private/group room creation, membership history, and access checks."

  import Ecto.Query, warn: false

  alias ChatApp.Accounts.{Scope, User}
  alias ChatApp.Blocking
  alias ChatApp.Repo
  alias ChatApp.Rooms.{Room, RoomMember}

  @doc "Creates a canonical one-to-one room, or returns the existing room for the pair."
  def create_private_room(%Scope{user: %User{id: user_id}}, other_user_id)
      when is_binary(other_user_id) do
    with {:ok, other_user_id} <- Ecto.UUID.cast(other_user_id),
         true <- other_user_id != user_id,
         :ok <-
           if(Blocking.blocked_between?(user_id, other_user_id),
             do: {:error, :blocked},
             else: :ok
           ),
         %User{deleted_at: nil} <- Repo.get(User, user_id),
         %User{deleted_at: nil} <- Repo.get(User, other_user_id) do
      [user_low_id, user_high_id] = Enum.sort([user_id, other_user_id])

      case Repo.transact(fn ->
             create_or_get_private_room(
               user_id,
               user_low_id,
               user_high_id
             )
           end) do
        {:ok, room} = result ->
          broadcast_room_activity(room, DateTime.utc_now(:second))
          result

        result ->
          result
      end
    else
      {:error, :blocked} -> {:error, :blocked}
      :error -> {:error, :invalid_participants}
      false -> {:error, :invalid_participants}
      _ -> {:error, :user_not_found}
    end
  end

  def create_private_room(_scope, _other_user_id), do: {:error, :invalid_participants}

  @doc "Creates a group room with the caller as its owner."
  def create_group_room(%Scope{user: %User{id: user_id}}, name) when is_binary(name) do
    name = String.trim(name)

    with true <- String.length(name) in 1..120,
         %User{deleted_at: nil} <- Repo.get(User, user_id),
         {:ok, room} <-
           Repo.transact(fn ->
             now = DateTime.utc_now(:second)

             room =
               %Room{id: Ecto.UUID.generate(), created_by: user_id}
               |> Room.changeset(%{type: "group", name: name})
               |> Repo.insert!()

             insert_group_membership!(room.id, user_id, "owner", now)
             {:ok, room}
           end) do
      broadcast_room_activity(room, DateTime.utc_now(:second))
      {:ok, room}
    else
      false -> {:error, :invalid_name}
      {:error, _} = error -> error
      _ -> {:error, :user_not_found}
    end
  end

  def create_group_room(_scope, _name), do: {:error, :invalid_name}

  @doc "Adds a user to a group room if the caller is an owner or admin."
  def add_group_member(%Scope{} = scope, room_id, user_id) do
    with {:ok, {room, actor}} <- get_room_for_user(scope, room_id),
         true <- room.type == "group" and actor.role in ["owner", "admin"],
         {:ok, user_id} <- cast_user_id(user_id),
         %User{deleted_at: nil} <- Repo.get(User, user_id),
         {:ok, member} <-
           Repo.transact(fn ->
             lock_room!(room.id)

             fresh_actor = active_membership(room.id, scope.user.id)

             unless fresh_actor && fresh_actor.role in ["owner", "admin"] do
               Repo.rollback(:forbidden)
             end

             if active_member?(%Scope{user: %User{id: user_id}}, room.id) do
               Repo.rollback(:already_member)
             end

             active_count =
               Repo.aggregate(
                 from(member in RoomMember,
                   where: member.room_id == ^room.id and is_nil(member.left_at)
                 ),
                 :count
               )

             if active_count >= 100, do: Repo.rollback(:group_full)

             joined_at = next_membership_joined_at(room.id, user_id)

             {:ok, insert_group_membership!(room.id, user_id, "member", joined_at)}
           end) do
      broadcast_membership_change(room, user_id, false)
      {:ok, member}
    else
      false -> {:error, :forbidden}
      nil -> {:error, :user_not_found}
      {:error, :already_member} = error -> error
      {:error, :group_full} = error -> error
      {:error, :forbidden} = error -> error
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Removes a group member; owners can remove admins, admins can remove members."
  def remove_group_member(%Scope{} = scope, room_id, target_user_id) do
    with {:ok, {room, actor}} <- get_room_for_user(scope, room_id),
         true <- room.type == "group" and actor.role in ["owner", "admin"],
         {:ok, target_user_id} <- cast_user_id(target_user_id),
         %RoomMember{} = target <- active_membership(room.id, target_user_id),
         true <- may_manage_member?(actor, target),
         {:ok, _member} <-
           Repo.transact(fn ->
             lock_room!(room.id)
             fresh_actor = active_membership(room.id, scope.user.id)
             fresh_target = active_membership(room.id, target_user_id)

             unless fresh_actor && fresh_target && may_manage_member?(fresh_actor, fresh_target) do
               Repo.rollback(:forbidden)
             end

             member =
               close_membership!(fresh_target)

             {:ok, member}
           end) do
      broadcast_membership_change(room, target_user_id, true)
      :ok
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, :forbidden} = error -> error
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Leaves a group; the owner must transfer ownership first."
  def leave_group(%Scope{} = scope, room_id) do
    with {:ok, {room, member}} <- get_room_for_user(scope, room_id),
         true <- room.type == "group" and member.role != "owner",
         {:ok, _member} <-
           Repo.transact(fn ->
             lock_room!(room.id)
             fresh_member = active_membership(room.id, scope.user.id)

             unless fresh_member && fresh_member.role != "owner" do
               Repo.rollback(:owner_must_transfer_ownership)
             end

             member =
               close_membership!(fresh_member)

             {:ok, member}
           end) do
      broadcast_membership_change(room, scope.user.id, true)
      :ok
    else
      false -> {:error, :owner_must_transfer_ownership}
      {:error, :owner_must_transfer_ownership} = error -> error
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "Owners can transfer ownership or assign/remove administrator privileges."
  def set_group_member_role(%Scope{} = scope, room_id, target_user_id, role)
      when role in ["owner", "admin", "member"] do
    with {:ok, {room, actor}} <- get_room_for_user(scope, room_id),
         true <- room.type == "group" and actor.role == "owner",
         {:ok, target_user_id} <- cast_user_id(target_user_id),
         %RoomMember{} <- active_membership(room.id, target_user_id),
         true <- target_user_id != actor.user_id or role == "owner",
         {:ok, _} <-
           Repo.transact(fn ->
             lock_room!(room.id)
             fresh_actor = active_membership(room.id, scope.user.id)
             fresh_target = active_membership(room.id, target_user_id)

             unless fresh_actor && fresh_target && fresh_actor.role == "owner" do
               Repo.rollback(:forbidden)
             end

             if role == "owner" and target_user_id != actor.user_id do
               fresh_actor |> Ecto.Changeset.change(role: "admin") |> Repo.update!()
             end

             target = fresh_target |> Ecto.Changeset.change(role: role) |> Repo.update!()
             {:ok, target}
           end) do
      broadcast_membership_change(room, target_user_id, false)
      :ok
    else
      false -> {:error, :forbidden}
      nil -> {:error, :not_found}
      {:error, :forbidden} = error -> error
      {:error, _} = error -> error
      _ -> {:error, :invalid_role}
    end
  end

  def set_group_member_role(_scope, _room_id, _target_user_id, _role),
    do: {:error, :invalid_role}

  @doc "Lists active room members with their profile and role."
  def list_room_members(%Scope{} = scope, room_id) do
    with {:ok, {_room, _member}} <- get_room_for_user(scope, room_id) do
      query =
        from member in RoomMember,
          join: user in assoc(member, :user),
          where:
            member.room_id == ^room_id and is_nil(member.left_at) and is_nil(user.deleted_at),
          order_by: [
            asc:
              fragment(
                "CASE WHEN ? = 'owner' THEN 0 WHEN ? = 'admin' THEN 1 ELSE 2 END",
                member.role,
                member.role
              ),
            asc: user.username
          ],
          select: %{member: member, user: user}

      {:ok, Repo.all(query)}
    end
  end

  def list_room_members(_scope, _room_id), do: {:error, :not_found}

  @doc "Lists all room types visible to the signed-in user for the room sidebar."
  def list_rooms(%Scope{} = scope) do
    list_private_rooms(scope) ++ list_group_rooms(scope)
  end

  def list_rooms(_scope), do: []

  defp list_group_rooms(%Scope{user: %User{id: user_id}}) do
    query =
      from room in Room,
        join: member in assoc(room, :members),
        where:
          room.type == "group" and is_nil(room.deleted_at) and member.user_id == ^user_id and
            is_nil(member.left_at),
        order_by: [desc: member.inserted_at],
        select: {room, member}

    Enum.map(Repo.all(query), fn {room, member} ->
      %{room: room, member: member, peer: nil, title: room.name, subtitle: "Group conversation"}
    end)
  end

  defp list_group_rooms(_scope), do: []

  @doc "Returns a room only when the caller has an active membership."
  def get_room_for_user(%Scope{user: %User{id: user_id}}, room_id) when is_binary(room_id) do
    case Ecto.UUID.cast(room_id) do
      {:ok, room_id} ->
        query =
          from room in Room,
            join: member in assoc(room, :members),
            where:
              room.id == ^room_id and is_nil(room.deleted_at) and member.user_id == ^user_id and
                is_nil(member.left_at),
            select: {room, member}

        case Repo.one(query) do
          {room, member} -> {:ok, {room, member}}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get_room_for_user(_scope, _room_id), do: {:error, :not_found}

  @doc "Returns the other participant after confirming the caller's active membership."
  def get_private_peer(%Scope{user: %User{id: user_id}} = scope, room_id) do
    with {:ok, {room, _member}} <- get_room_for_user(scope, room_id),
         peer_id <- if(room.user_low_id == user_id, do: room.user_high_id, else: room.user_low_id),
         %User{} = peer <- Repo.get(User, peer_id) do
      {:ok, peer}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_private_peer(_scope, _room_id), do: {:error, :not_found}

  @doc "Lists the caller's active private rooms with the other participant."
  def list_private_rooms(%Scope{user: %User{id: user_id}}) do
    query =
      from room in Room,
        join: member in assoc(room, :members),
        where:
          room.type == "private" and is_nil(room.deleted_at) and member.user_id == ^user_id and
            is_nil(member.left_at),
        order_by: [desc: member.inserted_at],
        select: {room, member}

    memberships = Repo.all(query)

    peer_ids =
      Enum.map(memberships, fn {room, _member} ->
        if room.user_low_id == user_id, do: room.user_high_id, else: room.user_low_id
      end)

    peers =
      if peer_ids == [] do
        []
      else
        Repo.all(from user in User, where: user.id in ^peer_ids and is_nil(user.deleted_at))
      end

    peers_by_id = Map.new(peers, &{&1.id, &1})

    Enum.flat_map(memberships, fn {room, member} ->
      peer_id = if room.user_low_id == user_id, do: room.user_high_id, else: room.user_low_id

      case peers_by_id[peer_id] do
        %User{} = peer ->
          [
            %{
              room: room,
              member: member,
              peer: peer,
              title: peer.display_name,
              subtitle: "@#{peer.username}"
            }
          ]

        nil ->
          []
      end
    end)
  end

  def list_private_rooms(_scope), do: []

  @doc "Looks up a non-deleted user by exact username, excluding the caller."
  def find_user_by_username(%Scope{user: %User{id: user_id}}, username)
      when is_binary(username) do
    username = username |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[a-zA-Z0-9_]{3,32}$/, username) do
      case Repo.one(
             from user in User,
               where:
                 user.username == ^username and user.id != ^user_id and is_nil(user.deleted_at),
               limit: 1
           ) do
        %User{} = user ->
          if Blocking.blocked_between?(user_id, user.id),
            do: {:error, :not_found},
            else: {:ok, user}

        nil ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  def find_user_by_username(_scope, _username), do: {:error, :not_found}

  @doc "Broadcasts lightweight room activity to both participants after access is checked."
  def broadcast_room_activity(%Scope{} = scope, room_id, %DateTime{} = at) do
    with {:ok, {room, _member}} <- get_room_for_user(scope, room_id) do
      broadcast_room_activity(room, at)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Checks whether a message timestamp falls within any of the caller's membership periods."
  def may_view_message_at?(%Scope{user: %User{id: user_id}}, room_id, %DateTime{} = created_at) do
    with {:ok, room_id} <- Ecto.UUID.cast(room_id) do
      query =
        from room in Room,
          join: member in assoc(room, :members),
          where:
            room.id == ^room_id and is_nil(room.deleted_at) and member.user_id == ^user_id and
              member.joined_at <= ^created_at and
              (is_nil(member.left_at) or member.left_at > ^created_at),
          select: count(member.id)

      Repo.one(query) > 0
    else
      _ -> false
    end
  end

  def may_view_message_at?(_scope, _room_id, _created_at), do: false

  @doc "Returns true only while the caller has an active membership in the room."
  def active_member?(%Scope{user: %User{id: user_id}}, room_id) when is_binary(room_id) do
    with {:ok, room_id} <- Ecto.UUID.cast(room_id) do
      query =
        from member in RoomMember,
          join: room in assoc(member, :room),
          where:
            room.id == ^room_id and is_nil(room.deleted_at) and member.user_id == ^user_id and
              is_nil(member.left_at),
          select: count(member.id)

      Repo.one(query) > 0
    else
      _ -> false
    end
  end

  def active_member?(_scope, _room_id), do: false

  @doc "Advances a member's delivered cursor without allowing it to move backwards."
  def advance_delivered(%Scope{} = scope, room_id, seq),
    do: advance_cursor(scope, room_id, seq, :delivered)

  def advance_delivered(_scope, _room_id, _seq), do: {:error, :not_authorized}

  @doc "Marks messages read monotonically; reading also implies delivery."
  def advance_read(%Scope{} = scope, room_id, seq),
    do: advance_cursor(scope, room_id, seq, :read)

  def advance_read(_scope, _room_id, _seq), do: {:error, :not_authorized}

  defp advance_cursor(scope, room_id, seq, mode)
       when is_integer(seq) and seq >= 0 do
    with {:ok, {room, membership}} <- get_room_for_user(scope, room_id),
         {:ok, latest_seq} <- ChatApp.Messaging.latest_sequence(room.id),
         true <- seq <= latest_seq do
      current_seq =
        if mode == :read, do: membership.last_read_seq, else: membership.last_delivered_seq

      if seq <= current_seq do
        :ok
      else
        update_member_cursor(scope, room, seq, mode)
      end
    else
      false -> {:error, :invalid_sequence}
      {:error, _} = error -> error
    end
  end

  defp advance_cursor(_scope, _room_id, _seq, _mode), do: {:error, :invalid_sequence}

  defp update_member_cursor(scope, room, seq, mode) do
    query =
      from member in RoomMember,
        where:
          member.room_id == ^room.id and member.user_id == ^scope.user.id and
            is_nil(member.left_at)

    now = DateTime.utc_now(:second)

    query =
      case mode do
        :delivered ->
          from member in query,
            update: [
              set: [
                last_delivered_seq: fragment("GREATEST(?, ?)", member.last_delivered_seq, ^seq),
                updated_at: ^now
              ]
            ]

        :read ->
          from member in query,
            update: [
              set: [
                last_delivered_seq: fragment("GREATEST(?, ?)", member.last_delivered_seq, ^seq),
                last_read_seq: fragment("GREATEST(?, ?)", member.last_read_seq, ^seq),
                updated_at: ^now
              ]
            ]
      end

    case Repo.update_all(query, []) do
      {count, _} when count > 0 ->
        Phoenix.PubSub.broadcast(
          ChatApp.PubSub,
          "user:#{scope.user.id}",
          {:room_cursor_updated, room.id}
        )

        :ok

      _ ->
        {:error, :not_found}
    end
  end

  defp create_or_get_private_room(created_by, user_low_id, user_high_id) do
    now = DateTime.utc_now(:second)
    room_id = Ecto.UUID.generate()

    room_attrs = %{
      id: room_id,
      type: "private",
      name: nil,
      created_by: created_by,
      user_low_id: user_low_id,
      user_high_id: user_high_id,
      inserted_at: now,
      updated_at: now
    }

    {inserted, _} =
      Repo.insert_all(Room, [room_attrs],
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, "(user_low_id, user_high_id) WHERE type = 'private'"}
      )

    if inserted == 1 do
      insert_initial_memberships(room_id, created_by, user_low_id, user_high_id, now)
      {:ok, Repo.get!(Room, room_id)}
    else
      case Repo.get_by(Room,
             user_low_id: user_low_id,
             user_high_id: user_high_id,
             type: "private"
           ) do
        %Room{deleted_at: nil} = room -> {:ok, room}
        _ -> {:error, :not_found}
      end
    end
  end

  defp broadcast_room_activity(%Room{} = room, %DateTime{} = at) do
    user_ids = active_room_user_ids(room.id)

    user_ids =
      if room.type == "private" do
        Enum.reject(user_ids, fn user_id ->
          Enum.any?(user_ids, fn other_user_id ->
            other_user_id != user_id and Blocking.blocked_between?(user_id, other_user_id)
          end)
        end)
      else
        user_ids
      end

    for user_id <- user_ids do
      Phoenix.PubSub.broadcast(
        ChatApp.PubSub,
        "user:#{user_id}",
        {:room_activity, room.id, at}
      )
    end

    :ok
  end

  defp broadcast_membership_change(room, user_id, revoked?) do
    Phoenix.PubSub.broadcast(
      ChatApp.PubSub,
      "room:#{room.id}",
      {:room_membership_changed, room.id, user_id}
    )

    if revoked? do
      Phoenix.PubSub.broadcast(ChatApp.PubSub, "user:#{user_id}", {:room_revoked, room.id})
    else
      broadcast_room_activity(room, DateTime.utc_now(:second))
    end

    :ok
  end

  defp active_room_user_ids(room_id) do
    Repo.all(
      from member in RoomMember,
        where: member.room_id == ^room_id and is_nil(member.left_at),
        select: member.user_id
    )
  end

  defp active_membership(room_id, user_id) do
    Repo.one(
      from member in RoomMember,
        where:
          member.room_id == ^room_id and member.user_id == ^user_id and is_nil(member.left_at),
        limit: 1
    )
  end

  defp lock_room!(room_id) do
    Repo.one!(from room in Room, where: room.id == ^room_id, lock: "FOR UPDATE")
  end

  defp may_manage_member?(actor, target) do
    cond do
      actor.role == "owner" -> target.role != "owner"
      actor.role == "admin" -> target.role == "member" and actor.user_id != target.user_id
      true -> false
    end
  end

  defp insert_group_membership!(room_id, user_id, role, now) do
    %RoomMember{room_id: room_id, user_id: user_id}
    |> RoomMember.changeset(%{role: role, joined_at: now})
    |> Repo.insert!()
  end

  defp close_membership!(member) do
    now = DateTime.utc_now(:second)

    left_at =
      if DateTime.compare(now, member.joined_at) == :gt,
        do: now,
        else: DateTime.add(member.joined_at, 1, :second)

    member
    |> RoomMember.changeset(%{left_at: left_at})
    |> Repo.update!()
  end

  defp next_membership_joined_at(room_id, user_id) do
    now = DateTime.utc_now(:second)

    previous_left_at =
      Repo.one(
        from member in RoomMember,
          where:
            member.room_id == ^room_id and member.user_id == ^user_id and
              not is_nil(member.left_at),
          order_by: [desc: member.left_at],
          limit: 1,
          select: member.left_at
      )

    if match?(%DateTime{}, previous_left_at) and DateTime.compare(now, previous_left_at) != :gt do
      DateTime.add(previous_left_at, 1, :second)
    else
      now
    end
  end

  defp cast_user_id(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, user_id} -> {:ok, user_id}
      :error -> {:error, :not_found}
    end
  end

  defp insert_initial_memberships(room_id, created_by, user_low_id, user_high_id, now) do
    members = [
      membership_attrs(
        room_id,
        user_low_id,
        if(created_by == user_low_id, do: "owner", else: "member"),
        now
      ),
      membership_attrs(
        room_id,
        user_high_id,
        if(created_by == user_high_id, do: "owner", else: "member"),
        now
      )
    ]

    {2, _} = Repo.insert_all(RoomMember, members)
  end

  defp membership_attrs(room_id, user_id, role, now) do
    %{
      id: Ecto.UUID.generate(),
      room_id: room_id,
      user_id: user_id,
      role: role,
      joined_at: now,
      left_at: nil,
      last_delivered_seq: 0,
      last_read_seq: 0,
      inserted_at: now,
      updated_at: now
    }
  end
end
