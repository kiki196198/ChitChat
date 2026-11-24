defmodule ChatApp.RoomsTest do
  use ChatApp.DataCase, async: false

  alias ChatApp.Accounts.{Scope, User}
  alias ChatApp.Repo
  alias ChatApp.Rooms
  alias ChatApp.Messaging
  alias ChatApp.Blocking
  alias ChatApp.Rooms.{Room, RoomMember}

  test "creates one canonical private room with exactly two memberships" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")

    assert {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)
    assert room.type == "private"
    assert room.created_by == alice.id
    assert room.user_low_id == min(alice.id, bob.id)
    assert room.user_high_id == max(alice.id, bob.id)

    memberships = Repo.all(from member in RoomMember, where: member.room_id == ^room.id)
    assert length(memberships) == 2
    assert Enum.count(memberships, &(&1.role == "owner")) == 1
    assert Enum.all?(memberships, &is_nil(&1.left_at))

    assert {:ok, {same_room, _member}} = Rooms.get_room_for_user(Scope.for_user(bob), room.id)
    assert same_room.id == room.id
  end

  test "reversed and concurrent requests return the same canonical room" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          caller = if rem(index, 2) == 0, do: alice, else: bob
          recipient = if caller.id == alice.id, do: bob.id, else: alice.id
          Rooms.create_private_room(Scope.for_user(caller), recipient)
        end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %Room{}}, &1))
    room_ids = Enum.map(results, fn {:ok, room} -> room.id end) |> Enum.uniq()
    assert length(room_ids) == 1
    assert Repo.aggregate(Room, :count) == 1
    assert Repo.aggregate(RoomMember, :count) == 2
  end

  test "nonmembers cannot fetch a room or view messages" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    mallory = user_fixture("mallory")
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)

    assert {:error, :not_found} = Rooms.get_room_for_user(Scope.for_user(mallory), room.id)
    assert {:error, :not_found} = Rooms.get_room_for_user(Scope.for_user(mallory), "bad-id")
    refute Rooms.active_member?(Scope.for_user(mallory), room.id)
    refute Rooms.may_view_message_at?(Scope.for_user(mallory), room.id, DateTime.utc_now())
  end

  test "message visibility follows each membership period" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)
    member = Repo.get_by!(RoomMember, room_id: room.id, user_id: bob.id)

    visible_time = DateTime.add(member.joined_at, 1, :second)
    left_at = DateTime.add(visible_time, 1, :second)
    later_time = DateTime.add(left_at, 1, :second)

    Repo.update!(Ecto.Changeset.change(member, left_at: left_at))

    assert Rooms.may_view_message_at?(Scope.for_user(bob), room.id, visible_time)
    refute Rooms.may_view_message_at?(Scope.for_user(bob), room.id, later_time)
    refute Rooms.active_member?(Scope.for_user(bob), room.id)
    assert {:error, :not_found} = Rooms.get_room_for_user(Scope.for_user(bob), room.id)
  end

  test "rejects creating a private room with yourself" do
    alice = user_fixture("alice")

    assert {:error, :invalid_participants} =
             Rooms.create_private_room(Scope.for_user(alice), alice.id)
  end

  test "the database prevents duplicate active membership" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)
    existing = Repo.get_by!(RoomMember, room_id: room.id, user_id: alice.id)

    changeset =
      %RoomMember{room_id: room.id, user_id: alice.id}
      |> RoomMember.changeset(%{role: existing.role, joined_at: DateTime.utc_now()})

    assert {:error, changeset} = Repo.insert(changeset)
    assert Keyword.has_key?(changeset.errors, :room_id)
  end

  test "creates a group with an owner and lists it with the caller's rooms" do
    alice = user_fixture("alice")
    scope = Scope.for_user(alice)

    assert {:ok, room} = Rooms.create_group_room(scope, "  Design circle  ")
    assert room.type == "group"
    assert room.name == "Design circle"
    assert room.created_by == alice.id
    assert {:ok, [owner]} = Rooms.list_room_members(scope, room.id)
    assert owner.user.id == alice.id
    assert owner.member.role == "owner"
    assert Enum.any?(Rooms.list_rooms(scope), &(&1.room.id == room.id))
  end

  test "group roles control invitations and removals while old membership periods stay closed" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    carol = user_fixture("carol")
    mallory = user_fixture("mallory")
    owner_scope = Scope.for_user(alice)
    bob_scope = Scope.for_user(bob)
    {:ok, room} = Rooms.create_group_room(owner_scope, "Project room")

    assert {:ok, bob_member} = Rooms.add_group_member(owner_scope, room.id, bob.id)
    assert bob_member.role == "member"
    assert {:error, :already_member} = Rooms.add_group_member(owner_scope, room.id, bob.id)
    assert {:error, :forbidden} = Rooms.add_group_member(bob_scope, room.id, carol.id)

    assert {:error, :not_found} =
             Rooms.add_group_member(Scope.for_user(mallory), room.id, carol.id)

    joined_at = bob_member.joined_at
    message_time = joined_at
    assert Rooms.may_view_message_at?(bob_scope, room.id, message_time)

    assert {:ok, _message} =
             Messaging.send_message(bob_scope, room.id, Ecto.UUID.generate(), "Old history")

    assert :ok = Rooms.set_group_member_role(owner_scope, room.id, bob.id, "admin")
    assert {:ok, _carol_member} = Rooms.add_group_member(bob_scope, room.id, carol.id)
    assert :ok = Rooms.remove_group_member(bob_scope, room.id, carol.id)

    assert :ok = Rooms.remove_group_member(owner_scope, room.id, bob.id)
    refute Rooms.active_member?(bob_scope, room.id)
    refute Rooms.may_view_message_at?(bob_scope, room.id, DateTime.add(joined_at, 5, :second))
    assert {:error, :not_found} = Rooms.list_room_members(bob_scope, room.id)

    assert {:ok, rejoined} = Rooms.add_group_member(owner_scope, room.id, bob.id)
    assert rejoined.id != bob_member.id
    left_member = Repo.get!(RoomMember, bob_member.id)
    assert DateTime.compare(rejoined.joined_at, left_member.left_at) == :gt
    assert {:ok, []} = Messaging.list_recent_messages(bob_scope, room.id)
    assert Rooms.may_view_message_at?(bob_scope, room.id, message_time)
  end

  test "ownership transfer is required before the creator can leave a group" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    alice_scope = Scope.for_user(alice)
    bob_scope = Scope.for_user(bob)
    {:ok, room} = Rooms.create_group_room(alice_scope, "Ownership")
    {:ok, _member} = Rooms.add_group_member(alice_scope, room.id, bob.id)

    assert {:error, :owner_must_transfer_ownership} = Rooms.leave_group(alice_scope, room.id)
    assert :ok = Rooms.set_group_member_role(alice_scope, room.id, bob.id, "owner")
    assert :ok = Rooms.leave_group(alice_scope, room.id)
    refute Rooms.active_member?(alice_scope, room.id)
    assert {:ok, {_room, %{role: "owner"}}} = Rooms.get_room_for_user(bob_scope, room.id)
  end

  test "delivered and read cursors move forward and unread counts follow read state" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    alice_scope = Scope.for_user(alice)
    bob_scope = Scope.for_user(bob)
    {:ok, room} = Rooms.create_private_room(alice_scope, bob.id)
    {:ok, first} = Messaging.send_message(alice_scope, room.id, Ecto.UUID.generate(), "First")
    {:ok, second} = Messaging.send_message(alice_scope, room.id, Ecto.UUID.generate(), "Second")

    assert {:ok, 2} = Messaging.unread_count(bob_scope, room.id)
    assert :ok = Rooms.advance_delivered(bob_scope, room.id, second.seq)
    assert :ok = Rooms.advance_delivered(bob_scope, room.id, first.seq)
    assert :ok = Rooms.advance_read(bob_scope, room.id, first.seq)

    assert {:ok, {_room, membership}} = Rooms.get_room_for_user(bob_scope, room.id)
    assert membership.last_delivered_seq == second.seq
    assert membership.last_read_seq == first.seq
    assert {:ok, 1} = Messaging.unread_count(bob_scope, room.id)

    assert :ok = Rooms.advance_read(bob_scope, room.id, second.seq)
    assert {:ok, 0} = Messaging.unread_count(bob_scope, room.id)
    assert {:error, :invalid_sequence} = Rooms.advance_read(bob_scope, room.id, second.seq + 1)
  end

  test "blocking prevents private room creation, lookup, sends and activity notifications" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    alice_scope = Scope.for_user(alice)
    {:ok, room} = Rooms.create_private_room(alice_scope, bob.id)
    room_id = room.id
    Phoenix.PubSub.subscribe(ChatApp.PubSub, "user:#{alice.id}")
    Phoenix.PubSub.subscribe(ChatApp.PubSub, "user:#{bob.id}")

    assert :ok = Blocking.block(alice_scope, bob.id)
    assert %{blocked_by_me?: true, blocked_me?: false} = Blocking.status(alice_scope, bob.id)
    assert {:error, :not_found} = Rooms.find_user_by_username(alice_scope, bob.username)
    assert {:error, :blocked} = Rooms.create_private_room(alice_scope, bob.id)

    assert {:error, :blocked} =
             Messaging.send_message(alice_scope, room.id, Ecto.UUID.generate(), "Blocked")

    assert_receive {:relationship_changed, _}
    assert_receive {:relationship_changed, _}
    assert :ok = Rooms.broadcast_room_activity(alice_scope, room.id, DateTime.utc_now(:second))
    refute_receive {:room_activity, ^room_id, _}, 30

    assert :ok = Blocking.unblock(alice_scope, bob.id)
    assert {:ok, _user} = Rooms.find_user_by_username(alice_scope, bob.username)
    assert {:ok, _room} = Rooms.create_private_room(alice_scope, bob.id)
  end

  defp user_fixture(prefix) do
    email = "#{prefix}-#{Ecto.UUID.generate()}@example.com"

    %User{}
    |> User.firebase_changeset(%{
      email: email,
      firebase_uid: Ecto.UUID.generate(),
      username: "#{prefix}_#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}",
      display_name: String.capitalize(prefix)
    })
    |> Repo.insert!()
  end
end
