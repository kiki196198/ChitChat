defmodule ChatAppWeb.RoomLive.Show do
  use ChatAppWeb, :live_view

  alias ChatApp.Rooms
  alias ChatApp.Messaging
  alias ChatApp.Blocking
  alias ChatAppWeb.Presence

  @stream_limit 100
  @max_message_length 4_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main class="app-content room-page">
        <div class="room-topline">
          <.link navigate={~p"/rooms"} class="room-back-link">
            <.icon name="hero-arrow-left" class="size-4" /> All conversations
          </.link>
          <span class="room-privacy-label"><span></span>{if @room.type == "group",
            do: "GROUP ROOM",
            else: "PRIVATE ROOM"}</span>
        </div>

        <section class="room-card">
          <header class="room-header">
            <div class="room-peer-avatar">
              <img :if={@peer && @peer.avatar_url} src={@peer.avatar_url} alt="" />
              <span :if={!@peer || !@peer.avatar_url}>{initial(
                (@room.type == "group" && @room.name) || @peer.display_name
              )}</span>
            </div>
            <div class="room-peer-details">
              <h1>{if @room.type == "group", do: @room.name, else: @peer.display_name}</h1>
              <span :if={@room.type == "private"}>@{@peer.username}</span>
              <span
                :if={@room.type == "private" && Map.get(@online_users, @peer.id, 0) > 0}
                class="room-online-status"
              >
                <i></i>Online
              </span>
              <span :if={@room.type == "group"}>{length(@members)} members</span>
            </div>
            <div class="room-header-note">
              <span class="eyebrow">{if @room.type == "group",
                do: "A shared conversation",
                else: "A private conversation"}</span>
            </div>
          </header>

          <div :if={@typing_text} class="room-typing-indicator" aria-live="polite">
            {@typing_text}
          </div>

          <div :if={@room.type == "private" && @block_status.blocked_by_me?} class="room-block-notice">
            You blocked this person. Unblock them to send messages again.
          </div>
          <div
            :if={
              @room.type == "private" && @block_status.blocked_me? && !@block_status.blocked_by_me?
            }
            class="room-block-notice"
          >
            This person has blocked you. You can't send messages in this conversation.
          </div>
          <div :if={@room.type == "private"} class="room-block-actions">
            <button type="button" phx-click="toggle_block">
              {if @block_status.blocked_by_me?, do: "Unblock", else: "Block"} @{@peer.username}
            </button>
          </div>

          <section
            :if={@room.type == "group"}
            class="group-members-panel"
            aria-labelledby="group-members-heading"
          >
            <div class="group-members-heading">
              <h2 id="group-members-heading">People in this room</h2>
              <span>{length(@members)} / 100</span>
            </div>
            <div class="group-member-list">
              <div :for={entry <- @members} class="group-member-row">
                <div>
                  <strong>{entry.user.display_name}</strong>
                  <span>
                    @{entry.user.username} · {String.capitalize(entry.member.role)}
                    <i :if={Map.get(@online_users, entry.user.id, 0) > 0} class="room-online-dot"></i>
                  </span>
                </div>
                <div class="group-member-actions">
                  <button
                    :if={@is_owner && entry.member.role == "member"}
                    type="button"
                    phx-click="change_member_role"
                    phx-value-user-id={entry.user.id}
                    phx-value-role="admin"
                  >Make admin</button>
                  <button
                    :if={@is_owner && entry.member.role == "admin"}
                    type="button"
                    phx-click="change_member_role"
                    phx-value-user-id={entry.user.id}
                    phx-value-role="member"
                  >Make member</button>
                  <button
                    :if={@is_owner && entry.member.role != "owner"}
                    type="button"
                    phx-click="change_member_role"
                    phx-value-user-id={entry.user.id}
                    phx-value-role="owner"
                  >Make owner</button>
                  <button
                    :if={
                      @can_manage && entry.member.role != "owner" &&
                        (@is_owner || entry.member.role == "member")
                    }
                    type="button"
                    class="group-member-remove"
                    phx-click="remove_member"
                    phx-value-user-id={entry.user.id}
                  >Remove</button>
                </div>
              </div>
            </div>
            <.form
              :if={@can_manage && length(@members) < 100}
              for={@member_form}
              id="add-group-member-form"
              phx-submit="add_member"
              class="group-member-add"
            >
              <.input
                field={@member_form[:username]}
                type="text"
                placeholder="Username to invite"
                aria-label="Username to invite"
                autocomplete="off"
                spellcheck="false"
                maxlength="32"
                required
              />
              <.button class="btn btn-primary" phx-disable-with="Adding…">Add member</.button>
            </.form>
            <p :if={@member_error} class="new-conversation-error">{@member_error}</p>
            <button
              :if={@room.type == "group" && !@is_owner}
              type="button"
              class="group-leave-button"
              phx-click="leave_group"
            >
              Leave group
            </button>
            <p :if={@room.type == "group" && @is_owner} class="group-owner-note">
              Transfer ownership before leaving this group.
            </p>
          </section>

          <div class="room-preview-notice">
            <.icon name="hero-sparkles" class="size-4 shrink-0" />
            {if @room.type == "group",
              do: "Messages are saved here for current group members.",
              else: "Messages are private and saved to this conversation."}
          </div>

          <div class="room-message-area">
            <div :if={@message_count == 0} class="room-empty-state">
              <span class="room-empty-rule"></span>
              <p>A little space for what's worth saying.</p>
              <span class="room-empty-rule"></span>
            </div>

            <div
              id="message-stream"
              phx-update="stream"
              phx-hook="ChatScroll"
              class="room-message-list"
              aria-live="polite"
              aria-relevant="additions"
            >
              <article
                :for={{dom_id, message} <- @streams.messages}
                id={dom_id}
                class={[
                  "room-message",
                  message.sender_id == @current_scope.user.id && "room-message-own"
                ]}
                data-seq={message.seq}
              >
                <div class="room-message-meta">
                  <span>{if message.sender_id == @current_scope.user.id,
                    do: "You",
                    else: if(@room.type == "group", do: message.sender_name, else: @peer.display_name)}</span>
                  <time datetime={DateTime.to_iso8601(message.inserted_at)}>
                    {Calendar.strftime(message.inserted_at, "%-I:%M %p")}
                  </time>
                  <span :if={message.sender_id == @current_scope.user.id} class="room-message-sent">Sent</span>
                </div>
                <p class="room-message-bubble">{message.body}</p>
              </article>
            </div>
          </div>

          <.form
            for={@message_form}
            id="message-composer"
            phx-submit="send_message"
            phx-hook="ChatComposer"
            data-room-id={@room.id}
            class="room-composer"
          >
            <.input
              field={@message_form[:client_message_id]}
              type="hidden"
              id="client-message-id"
            />
            <.input
              field={@message_form[:body]}
              type="textarea"
              id="message-body"
              rows="2"
              maxlength={@max_message_length}
              placeholder="Write a message…"
              aria-label="Message"
              class="room-composer-input"
              disabled={!@connected || @interaction_blocked?}
            />
            <div class="room-composer-footer">
              <span id="composer-status" class="room-composer-status" role="status" aria-live="polite">
                {@send_error || composer_status(@connected, @interaction_blocked?)}
              </span>
              <button
                id="send-message-button"
                type="submit"
                class="btn btn-primary room-send-button"
                disabled={!@connected || @interaction_blocked?}
                phx-disable-with="Sending…"
              >
                Send <.icon name="hero-arrow-up-right" class="size-4" />
              </button>
            </div>
          </.form>
        </section>
      </main>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => room_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, {room, _membership}} <- Rooms.get_room_for_user(scope, room_id),
         :ok <- subscribe_to_room(socket, room.id),
         {:ok, {room, membership}} <- Rooms.get_room_for_user(scope, room.id),
         {:ok, peer} <- get_peer(scope, room),
         {:ok, members} <- Rooms.list_room_members(scope, room.id),
         {:ok, messages} <- Messaging.list_recent_messages(scope, room.id, @stream_limit) do
      message_form =
        to_form(%{"body" => "", "client_message_id" => Ecto.UUID.generate()}, as: "message")

      block_status = if peer, do: Blocking.status(scope, peer.id), else: no_blocks()
      interaction_blocked? = block_status.blocked_by_me? or block_status.blocked_me?

      socket =
        socket
        |> assign(:room, room)
        |> assign(:membership, membership)
        |> assign(:peer, peer)
        |> assign(:members, members)
        |> assign(:is_owner, membership.role == "owner")
        |> assign(:can_manage, membership.role in ["owner", "admin"])
        |> assign(:member_form, to_form(%{"username" => ""}, as: "member"))
        |> assign(:member_error, nil)
        |> assign(:connected, connected?(socket))
        |> assign(:block_status, block_status)
        |> assign(:interaction_blocked?, interaction_blocked?)
        |> assign(:presence_topic, "room-presence:#{room.id}")
        |> assign(:presence_active, false)
        |> assign(:online_users, %{})
        |> assign(:typing_users, %{})
        |> assign(:typing_text, nil)
        |> assign(:typing_active, false)
        |> assign(:last_typing_sent_at, 0)
        |> assign(:message_form, message_form)
        |> assign(:max_message_length, @max_message_length)
        |> assign(:message_count, 0)
        |> assign(:message_cache, Map.new(messages, &{&1.seq, &1}))
        |> assign(:last_contiguous_seq, max_seq(messages))
        |> assign(:last_delivered_seq, membership.last_delivered_seq)
        |> assign(:send_error, nil)
        |> stream(:messages, messages, limit: -@stream_limit)
        |> assign(:message_count, length(messages))

      socket = update_room_presence(socket, not interaction_blocked?)

      if connected?(socket) do
        send(self(), :sync_delivered_messages)
      end

      {:ok, socket}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That conversation is unavailable.")
         |> push_navigate(to: ~p"/rooms")}
    end
  end

  @impl true
  def handle_event("sync_messages", _params, socket) do
    if Rooms.active_member?(socket.assigns.current_scope, socket.assigns.room.id) do
      {:noreply, socket |> sync_messages() |> sync_delivery_batch()}
    else
      {:noreply, revoke_room_access(socket)}
    end
  end

  def handle_event("mark_read", %{"seq" => seq}, socket) do
    case parse_sequence(seq) do
      seq when is_integer(seq) and seq <= socket.assigns.last_contiguous_seq ->
        Rooms.advance_read(socket.assigns.current_scope, socket.assigns.room.id, seq)
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "toggle_block",
        _params,
        %{assigns: %{room: %{type: "private"}, peer: peer}} = socket
      ) do
    scope = socket.assigns.current_scope

    result =
      if socket.assigns.block_status.blocked_by_me?,
        do: Blocking.unblock(scope, peer.id),
        else: Blocking.block(scope, peer.id)

    case result do
      :ok ->
        block_status = Blocking.status(scope, peer.id)
        blocked? = block_status.blocked_by_me? or block_status.blocked_me?

        {:noreply,
         socket
         |> assign(:block_status, block_status)
         |> assign(:interaction_blocked?, blocked?)
         |> assign(:send_error, nil)
         |> then(fn socket -> if(blocked?, do: stop_typing(socket), else: socket) end)
         |> then(fn socket ->
           if(blocked?, do: assign_typing_users(socket, %{}), else: socket)
         end)
         |> update_room_presence(not blocked?)}

      _ ->
        {:noreply, assign(socket, :send_error, "That account action could not be saved.")}
    end
  end

  def handle_event("typing", %{"typing" => true}, socket) do
    if connected?(socket) and not socket.assigns.interaction_blocked? and
         Rooms.active_member?(socket.assigns.current_scope, socket.assigns.room.id) do
      now = System.monotonic_time(:millisecond)

      if not socket.assigns.typing_active or now - socket.assigns.last_typing_sent_at >= 900 do
        Phoenix.PubSub.broadcast(
          ChatApp.PubSub,
          "room:#{socket.assigns.room.id}",
          {:typing, socket.assigns.current_scope.user.id,
           socket.assigns.current_scope.user.display_name, true}
        )

        {:noreply,
         socket
         |> assign(:typing_active, true)
         |> assign(:last_typing_sent_at, now)}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("typing", %{"typing" => false}, socket), do: {:noreply, stop_typing(socket)}

  def handle_event("typing", _params, socket), do: {:noreply, socket}

  def handle_event("add_member", %{"member" => %{"username" => username}}, socket) do
    with {:ok, user} <- Rooms.find_user_by_username(socket.assigns.current_scope, username),
         {:ok, _member} <-
           Rooms.add_group_member(socket.assigns.current_scope, socket.assigns.room.id, user.id) do
      {:noreply,
       socket
       |> refresh_members()
       |> assign(:member_error, nil)
       |> assign(:member_form, to_form(%{"username" => ""}, as: "member"))}
    else
      {:error, :already_member} ->
        {:noreply, assign(socket, :member_error, "That person is already in this room.")}

      _ ->
        {:noreply, assign(socket, :member_error, "We couldn't add that username to this room.")}
    end
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    case Rooms.remove_group_member(socket.assigns.current_scope, socket.assigns.room.id, user_id) do
      :ok ->
        {:noreply, refresh_members(socket)}

      _ ->
        {:noreply,
         assign(socket, :member_error, "You don't have permission to remove that member.")}
    end
  end

  def handle_event("change_member_role", %{"user-id" => user_id, "role" => role}, socket) do
    case Rooms.set_group_member_role(
           socket.assigns.current_scope,
           socket.assigns.room.id,
           user_id,
           role
         ) do
      :ok -> {:noreply, refresh_members(socket)}
      _ -> {:noreply, assign(socket, :member_error, "Only the owner can change group roles.")}
    end
  end

  def handle_event("leave_group", _params, socket) do
    case Rooms.leave_group(socket.assigns.current_scope, socket.assigns.room.id) do
      :ok -> {:noreply, push_navigate(socket, to: ~p"/rooms")}
      _ -> {:noreply, put_flash(socket, :error, "Transfer ownership before leaving the group.")}
    end
  end

  @impl true
  def handle_event("send_message", params, socket) do
    params = if is_map(params["message"]), do: params["message"], else: params
    body = if is_binary(params["body"]), do: params["body"], else: ""
    client_message_id = params["client_message_id"]
    content = String.trim(body)

    cond do
      not connected?(socket) ->
        {:noreply, assign(socket, :send_error, "Reconnecting… your draft is kept.")}

      String.length(content) == 0 ->
        {:noreply, assign(socket, :send_error, "Write a message before sending.")}

      String.length(content) > @max_message_length ->
        {:noreply,
         socket
         |> assign(:send_error, "Messages can be up to #{@max_message_length} characters.")
         |> update_message_form(body, client_message_id)}

      true ->
        case Ecto.UUID.cast(client_message_id) do
          {:ok, client_message_id} ->
            send_authorized_message(socket, content, client_message_id)

          :error ->
            {:noreply,
             socket
             |> assign(:send_error, "Please retry sending your message.")
             |> update_message_form(body, Ecto.UUID.generate())}
        end
    end
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    if Rooms.active_member?(socket.assigns.current_scope, socket.assigns.room.id) do
      last_seq = socket.assigns.last_contiguous_seq

      cond do
        message.seq <= last_seq ->
          {:noreply, socket}

        message.seq == last_seq + 1 ->
          socket = socket |> merge_messages([message]) |> sync_delivery_batch()
          {:noreply, socket}

        true ->
          socket = merge_messages(socket, [message])
          {:noreply, socket |> sync_messages() |> sync_delivery_batch()}
      end
    else
      {:noreply, revoke_room_access(socket)}
    end
  end

  @impl true
  def handle_info(:sync_more_messages, socket) do
    if Rooms.active_member?(socket.assigns.current_scope, socket.assigns.room.id) do
      {:noreply, socket |> sync_messages() |> sync_delivery_batch()}
    else
      {:noreply, revoke_room_access(socket)}
    end
  end

  def handle_info(:sync_delivered_messages, socket) do
    if Rooms.active_member?(socket.assigns.current_scope, socket.assigns.room.id) do
      {:noreply, sync_delivery_batch(socket)}
    else
      {:noreply, revoke_room_access(socket)}
    end
  end

  def handle_info(
        {:typing, user_id, _display_name, _typing},
        %{assigns: %{current_scope: %{user: %{id: user_id}}}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:typing, user_id, display_name, true}, socket) do
    if typing_blocked?(socket, user_id) do
      {:noreply, socket}
    else
      expires_at = System.monotonic_time(:millisecond) + 3_500
      Process.send_after(self(), {:expire_typing, user_id, expires_at}, 3_500)

      typing_users =
        Map.put(socket.assigns.typing_users, user_id, %{
          display_name: display_name,
          expires_at: expires_at
        })

      {:noreply, assign_typing_users(socket, typing_users)}
    end
  end

  def handle_info({:typing, user_id, _display_name, false}, socket) do
    {:noreply, remove_typing_user(socket, user_id)}
  end

  def handle_info({:expire_typing, user_id, expires_at}, socket) do
    case socket.assigns.typing_users[user_id] do
      %{expires_at: ^expires_at} -> {:noreply, remove_typing_user(socket, user_id)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket)
      when topic == socket.assigns.presence_topic do
    {:noreply, assign(socket, :online_users, presence_users(topic))}
  end

  def handle_info({:relationship_changed, other_user_id}, socket) do
    if socket.assigns.peer && socket.assigns.peer.id == other_user_id do
      block_status = Blocking.status(socket.assigns.current_scope, other_user_id)
      blocked? = block_status.blocked_by_me? or block_status.blocked_me?

      {:noreply,
       socket
       |> assign(:block_status, block_status)
       |> assign(:interaction_blocked?, blocked?)
       |> then(fn socket -> if(blocked?, do: stop_typing(socket), else: socket) end)
       |> then(fn socket ->
         if blocked?, do: assign_typing_users(socket, %{}), else: socket
       end)
       |> update_room_presence(not blocked?)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:room_activity, _room_id, _at}, socket), do: {:noreply, socket}
  def handle_info({:room_cursor_updated, _room_id}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:room_membership_changed, room_id, _user_id}, socket)
      when room_id == socket.assigns.room.id do
    if Rooms.active_member?(socket.assigns.current_scope, room_id) do
      {:noreply, refresh_members(socket)}
    else
      {:noreply, revoke_room_access(socket)}
    end
  end

  @impl true
  def handle_info({:room_revoked, room_id}, socket) when room_id == socket.assigns.room.id do
    {:noreply, revoke_room_access(socket)}
  end

  def handle_info({:room_revoked, _room_id}, socket), do: {:noreply, socket}

  defp sync_messages(socket) do
    scope = socket.assigns.current_scope
    room_id = socket.assigns.room.id

    case Messaging.list_messages_after(
           scope,
           room_id,
           socket.assigns.last_contiguous_seq,
           @stream_limit
         ) do
      {:ok, []} ->
        assign(socket, :send_error, nil)

      {:ok, messages} ->
        socket = merge_messages(socket, messages)

        if length(messages) == @stream_limit do
          send(self(), :sync_more_messages)
        end

        socket

      {:error, _reason} ->
        assign(socket, :send_error, "Message history could not be refreshed. Retry shortly.")
    end
  end

  defp sync_delivery_batch(socket) do
    case Messaging.list_messages_after(
           socket.assigns.current_scope,
           socket.assigns.room.id,
           socket.assigns.last_delivered_seq,
           @stream_limit
         ) do
      {:ok, []} ->
        socket

      {:ok, messages} ->
        seq = messages |> Enum.map(& &1.seq) |> Enum.max()

        case Rooms.advance_delivered(socket.assigns.current_scope, socket.assigns.room.id, seq) do
          :ok ->
            socket =
              socket
              |> merge_messages(messages)
              |> assign(:last_delivered_seq, seq)

            if length(messages) == @stream_limit do
              send(self(), :sync_delivered_messages)
            end

            socket

          _ ->
            socket
        end

      {:error, _reason} ->
        assign(socket, :send_error, "Delivery sync could not complete. Retry shortly.")
    end
  end

  defp merge_messages(socket, messages) do
    cache =
      Enum.reduce(messages, socket.assigns.message_cache, fn message, acc ->
        Map.put_new(acc, message.seq, message)
      end)

    last_contiguous_seq = advance_contiguous(socket.assigns.last_contiguous_seq, cache)
    ordered = cache |> Map.values() |> Enum.sort_by(& &1.seq) |> Enum.take(-@stream_limit)
    kept_cache = Map.new(ordered, &{&1.seq, &1})

    socket
    |> stream(:messages, ordered, reset: true, limit: -@stream_limit)
    |> assign(:message_cache, kept_cache)
    |> assign(:message_count, length(ordered))
    |> assign(:last_contiguous_seq, last_contiguous_seq)
    |> assign(:send_error, nil)
  end

  defp advance_contiguous(last_seq, cache) do
    if Map.has_key?(cache, last_seq + 1),
      do: advance_contiguous(last_seq + 1, cache),
      else: last_seq
  end

  defp revoke_room_access(socket) do
    Phoenix.PubSub.unsubscribe(ChatApp.PubSub, "room:#{socket.assigns.room.id}")
    Phoenix.PubSub.unsubscribe(ChatApp.PubSub, "user:#{socket.assigns.current_scope.user.id}")

    socket
    |> update_room_presence(false)
    |> stream(:messages, [], reset: true)
    |> assign(:message_cache, %{})
    |> assign(:members, [])
    |> push_navigate(to: ~p"/rooms")
  end

  defp subscribe_to_room(socket, room_id) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ChatApp.PubSub, "room:#{room_id}")
      Phoenix.PubSub.subscribe(ChatApp.PubSub, "user:#{socket.assigns.current_scope.user.id}")
    end

    :ok
  end

  defp update_room_presence(socket, should_track?) do
    topic = socket.assigns.presence_topic
    user_id = socket.assigns.current_scope.user.id

    cond do
      connected?(socket) and should_track? and not socket.assigns.presence_active ->
        Phoenix.PubSub.subscribe(ChatApp.PubSub, topic)

        case Presence.track(self(), topic, user_id, %{online_at: System.system_time(:second)}) do
          {:ok, _ref} ->
            socket
            |> assign(:presence_active, true)
            |> assign(:online_users, presence_users(topic))

          {:error, _reason} ->
            Phoenix.PubSub.unsubscribe(ChatApp.PubSub, topic)
            socket
        end

      socket.assigns.presence_active and not should_track? ->
        Presence.untrack(self(), topic, user_id)
        Phoenix.PubSub.unsubscribe(ChatApp.PubSub, topic)

        socket
        |> assign(:presence_active, false)
        |> assign(:online_users, %{})

      socket.assigns.presence_active ->
        assign(socket, :online_users, presence_users(topic))

      true ->
        assign(socket, :online_users, %{})
    end
  end

  defp presence_users(topic) do
    Presence.list(topic)
    |> Map.new(fn {user_id, %{metas: metas}} -> {user_id, length(metas)} end)
  end

  defp stop_typing(socket) do
    if socket.assigns.typing_active do
      Phoenix.PubSub.broadcast(
        ChatApp.PubSub,
        "room:#{socket.assigns.room.id}",
        {:typing, socket.assigns.current_scope.user.id,
         socket.assigns.current_scope.user.display_name, false}
      )
    end

    assign(socket, :typing_active, false)
  end

  defp typing_blocked?(
         %{assigns: %{room: %{type: "private"}, current_scope: %{user: %{id: user_id}}}},
         other_user_id
       ) do
    Blocking.blocked_between?(user_id, other_user_id)
  end

  defp typing_blocked?(_socket, _other_user_id), do: false

  defp assign_typing_users(socket, typing_users) do
    socket
    |> assign(:typing_users, typing_users)
    |> assign(:typing_text, typing_text(typing_users))
  end

  defp remove_typing_user(socket, user_id) do
    socket.assigns.typing_users
    |> Map.delete(user_id)
    |> then(&assign_typing_users(socket, &1))
  end

  defp typing_text(typing_users) when map_size(typing_users) == 0, do: nil

  defp typing_text(typing_users) do
    names = typing_users |> Map.values() |> Enum.map(& &1.display_name)

    case names do
      [name] -> "#{name} is typing…"
      _ -> "#{length(names)} people are typing…"
    end
  end

  defp parse_sequence(seq) when is_integer(seq) and seq >= 0, do: seq

  defp parse_sequence(seq) when is_binary(seq) do
    case Integer.parse(seq) do
      {seq, ""} when seq >= 0 -> seq
      _ -> :error
    end
  end

  defp parse_sequence(_seq), do: :error

  defp no_blocks, do: %{blocked_by_me?: false, blocked_me?: false}

  defp composer_status(_connected, true), do: "Messaging is disabled while a block is active."
  defp composer_status(true, false), do: "Only people in this room can see your messages."
  defp composer_status(false, false), do: "Reconnecting… your draft is kept."

  defp refresh_members(socket) do
    case Rooms.list_room_members(socket.assigns.current_scope, socket.assigns.room.id) do
      {:ok, members} ->
        membership = Enum.find(members, &(&1.user.id == socket.assigns.current_scope.user.id))

        socket
        |> assign(:members, members)
        |> assign(:membership, membership.member)
        |> assign(:is_owner, membership.member.role == "owner")
        |> assign(:can_manage, membership.member.role in ["owner", "admin"])

      _ ->
        revoke_room_access(socket)
    end
  end

  defp get_peer(_scope, %{type: "group"}), do: {:ok, nil}
  defp get_peer(scope, room), do: Rooms.get_private_peer(scope, room.id)

  defp max_seq([]), do: 0
  defp max_seq(messages), do: messages |> Enum.map(& &1.seq) |> Enum.max()

  defp send_authorized_message(socket, body, client_message_id) do
    with {:ok, {_room, _membership}} <-
           Rooms.get_room_for_user(socket.assigns.current_scope, socket.assigns.room.id) do
      case Messaging.send_message(
             socket.assigns.current_scope,
             socket.assigns.room.id,
             client_message_id,
             body
           ) do
        {:ok, message} ->
          Phoenix.PubSub.broadcast(
            ChatApp.PubSub,
            "room:#{socket.assigns.room.id}",
            {:new_message, message}
          )

          next_client_message_id = Ecto.UUID.generate()

          Rooms.broadcast_room_activity(
            socket.assigns.current_scope,
            socket.assigns.room.id,
            message.inserted_at
          )

          {:noreply,
           socket
           |> assign(
             :message_form,
             to_form(%{"body" => "", "client_message_id" => next_client_message_id},
               as: "message"
             )
           )
           |> assign(:send_error, nil)
           |> push_event("message-acknowledged", %{next_id: next_client_message_id})}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:send_error, "Your message could not be sent. Retry when you're connected.")
           |> update_message_form(body, client_message_id)}
      end
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Room access has changed.")
         |> stream(:messages, [], reset: true)
         |> push_navigate(to: ~p"/rooms")}
    end
  end

  defp update_message_form(socket, body, client_message_id) do
    id = if is_binary(client_message_id), do: client_message_id, else: Ecto.UUID.generate()

    assign(
      socket,
      :message_form,
      to_form(%{"body" => body, "client_message_id" => id}, as: "message")
    )
  end

  defp initial(name), do: name |> String.trim() |> String.first() |> String.upcase()
end
