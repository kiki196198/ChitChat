defmodule ChatAppWeb.RoomLiveTest do
  use ChatAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ChatApp.Accounts.{Scope, User}
  alias ChatApp.Repo
  alias ChatApp.Rooms
  alias ChatApp.Messaging
  alias ChatAppWeb.Presence

  test "room list shows the caller's private rooms and listens for activity", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    {:ok, lv, _html} = conn |> log_in_user(alice) |> live(~p"/rooms")

    assert render(lv) =~ "Your conversations start here."

    {:ok, _room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)

    assert render(lv) =~ bob.display_name
    assert render(lv) =~ "@#{bob.username}"
  end

  test "only active members can mount a room view", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    mallory = user_fixture("mallory")
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)

    assert {:ok, _view, html} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")
    assert html =~ bob.display_name
    assert html =~ "Messages are private and saved"

    assert {:error, {:live_redirect, %{to: "/rooms"}}} =
             conn |> log_in_user(mallory) |> live(~p"/rooms/#{room.id}")
  end

  test "messages persist in sequence order and retries return the original", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    scope = Scope.for_user(alice)
    {:ok, room} = Rooms.create_private_room(scope, bob.id)
    client_message_id = Ecto.UUID.generate()

    assert {:ok, first} = Messaging.send_message(scope, room.id, client_message_id, "Persist me")
    assert {:ok, retry} = Messaging.send_message(scope, room.id, client_message_id, "Persist me")
    assert retry.id == first.id
    assert retry.seq == first.seq

    assert {:ok, second} =
             Messaging.send_message(scope, room.id, Ecto.UUID.generate(), "Second message")

    assert {:ok, history} = Messaging.list_recent_messages(scope, room.id)
    assert Enum.map(history, & &1.seq) == [first.seq, second.seq]
    assert {:ok, [first]} = Messaging.list_messages_before(scope, room.id, second.seq)
    assert {:ok, [^second]} = Messaging.list_messages_after(scope, room.id, first.seq)
    assert hd(history).body == "Persist me"

    {:ok, _view, html} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")
    assert html =~ "Persist me"
  end

  test "concurrent sends receive distinct increasing room sequences" do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    scope = Scope.for_user(alice)
    {:ok, room} = Rooms.create_private_room(scope, bob.id)

    tasks =
      for index <- 1..12 do
        Task.async(fn ->
          receive do
            :send -> :ok
          end

          Messaging.send_message(scope, room.id, Ecto.UUID.generate(), "Concurrent #{index}")
        end)
      end

    Enum.each(tasks, fn task -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid) end)
    Enum.each(tasks, &send(&1.pid, :send))

    messages = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.all?(messages, &match?({:ok, _}, &1))

    sequences = Enum.map(messages, fn {:ok, message} -> message.seq end)
    assert length(Enum.uniq(sequences)) == 12

    assert {:ok, history} = Messaging.list_recent_messages(scope, room.id, 100)
    assert Enum.map(history, & &1.seq) == Enum.sort(sequences)
  end

  test "a failed message transaction rolls back its sequence allocation" do
    room_id = Ecto.UUID.generate()

    assert {:error, :forced_abort} =
             Mongo.transaction(ChatApp.Mongo, fn opts ->
               Mongo.find_one_and_update(
                 ChatApp.Mongo,
                 "room_message_counters",
                 %{"_id" => room_id},
                 %{"$inc" => %{seq: 1}},
                 upsert: true,
                 return_document: :after,
                 session: Keyword.fetch!(opts, :session)
               )

               {:error, :forced_abort}
             end)

    assert Mongo.find_one(ChatApp.Mongo, "room_message_counters", %{"_id" => room_id}) == nil
  end

  test "connected room members receive live messages", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)

    {:ok, alice_view, _} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")
    {:ok, bob_view, _} = conn |> log_in_user(bob) |> live(~p"/rooms/#{room.id}")

    message = "A quiet hello"

    [_, client_message_id] =
      Regex.run(~r/id="client-message-id"[^>]*value="([^"]+)"/, render(alice_view))

    alice_view
    |> form("#message-composer", %{
      "message" => %{
        "body" => message,
        "client_message_id" => client_message_id
      }
    })
    |> render_submit()

    assert length(String.split(render(alice_view), message)) == 2
    assert length(String.split(render(bob_view), message)) == 2

    [_, next_client_message_id] =
      Regex.run(~r/id="client-message-id"[^>]*value="([^"]+)"/, render(alice_view))

    refute next_client_message_id == client_message_id
  end

  test "presence counts multiple sessions and typing is room scoped", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)

    {:ok, alice_view, _} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")
    {:ok, _second_alice_view, _} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")
    {:ok, bob_view, _} = conn |> log_in_user(bob) |> live(~p"/rooms/#{room.id}")

    topic = "room-presence:#{room.id}"
    assert length(Presence.list(topic)[alice.id].metas) == 2
    assert render(bob_view) =~ "Online"

    alice_view |> element("#message-composer") |> render_hook("typing", %{"typing" => true})
    assert render(bob_view) =~ "Alice is typing"

    alice_view |> element("#message-composer") |> render_hook("typing", %{"typing" => false})
    refute render(bob_view) =~ "Alice is typing"
  end

  test "visible messages advance the read cursor", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    bob_scope = Scope.for_user(bob)
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)

    {:ok, message} =
      Messaging.send_message(Scope.for_user(alice), room.id, Ecto.UUID.generate(), "Read me")

    {:ok, bob_view, _} = conn |> log_in_user(bob) |> live(~p"/rooms/#{room.id}")
    bob_view |> element("#message-stream") |> render_hook("mark_read", %{"seq" => message.seq})

    assert {:ok, {_room, membership}} = Rooms.get_room_for_user(bob_scope, room.id)
    assert membership.last_read_seq == message.seq
  end

  test "reconnect sync recovers missed messages and fills out-of-order delivery", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    scope = Scope.for_user(alice)
    {:ok, room} = Rooms.create_private_room(scope, bob.id)
    {:ok, view, _} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")

    {:ok, first} = Messaging.send_message(scope, room.id, Ecto.UUID.generate(), "Recovered one")
    {:ok, second} = Messaging.send_message(scope, room.id, Ecto.UUID.generate(), "Recovered two")
    {:ok, third} = Messaging.send_message(scope, room.id, Ecto.UUID.generate(), "Recovered three")

    Phoenix.PubSub.broadcast(
      ChatApp.PubSub,
      "room:#{room.id}",
      {:new_message, third}
    )

    html = render(view)
    assert html =~ "Recovered one"
    assert html =~ "Recovered two"
    assert html =~ "Recovered three"
    assert :binary.match(html, "Recovered one") < :binary.match(html, "Recovered two")
    assert :binary.match(html, "Recovered two") < :binary.match(html, "Recovered three")

    Phoenix.PubSub.broadcast(
      ChatApp.PubSub,
      "room:#{room.id}",
      {:new_message, second}
    )

    html = render(view)
    assert length(String.split(html, "Recovered two")) == 2

    view |> element("#message-composer") |> render_hook("sync_messages", %{})
    assert length(String.split(render(view), "Recovered three")) == 2
    assert first.seq + 1 == second.seq
    assert second.seq + 1 == third.seq
  end

  test "retry after a committed send reuses the message instead of duplicating it", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    scope = Scope.for_user(alice)
    {:ok, room} = Rooms.create_private_room(scope, bob.id)
    {:ok, view, _} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")

    [_, client_message_id] =
      Regex.run(~r/id="client-message-id"[^>]*value="([^"]+)"/, render(view))

    {:ok, stored} =
      Messaging.send_message(scope, room.id, client_message_id, "Retry after ack loss")

    view
    |> form("#message-composer", %{
      "message" => %{"body" => "Retry after ack loss", "client_message_id" => client_message_id}
    })
    |> render_submit()

    assert length(String.split(render(view), "Retry after ack loss")) == 2
    assert {:ok, [^stored]} = Messaging.list_recent_messages(scope, room.id)
  end

  test "disconnected HTML renders the composer disabled", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    {:ok, room} = Rooms.create_private_room(Scope.for_user(alice), bob.id)

    html =
      conn
      |> log_in_user(alice)
      |> get(~p"/rooms/#{room.id}")
      |> html_response(200)

    assert html =~ ~r/id="message-body"[^>]*disabled/
    assert html =~ ~r/id="send-message-button"[^>]*disabled/
  end

  test "group members can chat and removed members are revoked immediately", %{conn: conn} do
    alice = user_fixture("alice")
    bob = user_fixture("bob")
    alice_scope = Scope.for_user(alice)
    bob_scope = Scope.for_user(bob)
    {:ok, group_index, _} = conn |> log_in_user(alice) |> live(~p"/rooms")

    group_index
    |> form("#new-group-form", %{"group" => %{"name" => "Weekend plans"}})
    |> render_submit()

    {room_path, _flash} = assert_redirect(group_index)
    room_id = String.replace_prefix(room_path, "/rooms/", "")
    {:ok, {room, _owner}} = Rooms.get_room_for_user(alice_scope, room_id)

    {:ok, _index, index_html} = conn |> log_in_user(alice) |> live(~p"/rooms")
    assert index_html =~ "Weekend plans"
    assert index_html =~ "Group conversation"

    {:ok, alice_view, alice_html} = conn |> log_in_user(alice) |> live(~p"/rooms/#{room.id}")

    alice_view
    |> form("#add-group-member-form", %{"member" => %{"username" => bob.username}})
    |> render_submit()

    {:ok, bob_view, bob_html} = conn |> log_in_user(bob) |> live(~p"/rooms/#{room.id}")
    assert alice_html =~ "Weekend plans"
    assert bob_html =~ "Weekend plans"
    assert bob_html =~ "Alice"

    {:ok, message} =
      Messaging.send_message(bob_scope, room.id, Ecto.UUID.generate(), "Group hello")

    Phoenix.PubSub.broadcast(ChatApp.PubSub, "room:#{room.id}", {:new_message, message})
    assert render(alice_view) =~ "Group hello"

    alice_view
    |> element("button[phx-click=remove_member][phx-value-user-id='#{bob.id}']")
    |> render_click()

    refute render(alice_view) =~ "@#{bob.username}"
    assert_redirect(bob_view, "/rooms")

    assert {:error, {:live_redirect, %{to: "/rooms"}}} =
             conn |> log_in_user(bob) |> live(~p"/rooms/#{room.id}")
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
