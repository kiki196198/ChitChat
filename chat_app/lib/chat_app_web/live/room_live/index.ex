defmodule ChatAppWeb.RoomLive.Index do
  use ChatAppWeb, :live_view

  alias ChatApp.Rooms
  alias ChatApp.Messaging

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main class="app-content rooms-index">
        <div class="rooms-heading">
          <div>
            <p class="eyebrow">Your conversations</p>
            <h1>Conversations</h1>
            <p class="rooms-intro">A quieter place to pick up where it matters.</p>
          </div>
          <span class="rooms-count">{length(@rooms)} {if length(@rooms) == 1,
            do: "room",
            else: "rooms"}</span>
        </div>

        <section class="new-conversation-card" aria-labelledby="new-conversation-heading">
          <div class="new-conversation-copy">
            <span class="section-index">01</span>
            <div>
              <h2 id="new-conversation-heading">Start a conversation</h2>
              <p>Enter someone's username to open a private room.</p>
            </div>
          </div>
          <.form
            for={@search_form}
            id="new-conversation-form"
            phx-submit="start_conversation"
            phx-change="validate_username"
            class="new-conversation-form"
          >
            <.input
              field={@search_form[:username]}
              type="text"
              label="Username"
              placeholder="their_username"
              autocomplete="off"
              spellcheck="false"
              maxlength="32"
              required
            />
            <.button class="btn btn-primary" phx-disable-with="Opening…">
              Open private room <span aria-hidden="true">↗</span>
            </.button>
          </.form>
          <p :if={@search_error} class="new-conversation-error">{@search_error}</p>
        </section>

        <section class="new-conversation-card group-create-card" aria-labelledby="new-group-heading">
          <div class="new-conversation-copy">
            <span class="section-index">02</span>
            <div>
              <h2 id="new-group-heading">Create a group</h2>
              <p>Give your group a name. You can invite members inside the room.</p>
            </div>
          </div>
          <.form
            for={@group_form}
            id="new-group-form"
            phx-submit="create_group"
            class="new-conversation-form"
          >
            <.input
              field={@group_form[:name]}
              type="text"
              label="Group name"
              placeholder="Studio team"
              maxlength="120"
              required
            />
            <.button class="btn btn-primary" phx-disable-with="Creating…">
              Create group <span aria-hidden="true">↗</span>
            </.button>
          </.form>
          <p :if={@group_error} class="new-conversation-error">{@group_error}</p>
        </section>

        <section class="conversation-list-section" aria-labelledby="conversation-list-heading">
          <div class="section-heading-row">
            <h2 id="conversation-list-heading">Your rooms</h2>
            <span>PRIVATE &amp; GROUP ROOMS</span>
          </div>

          <div :if={@rooms == []} class="rooms-empty-state">
            <span class="empty-mark" aria-hidden="true">C</span>
            <h3>Your conversations start here.</h3>
            <p>Open a private conversation or create a group above.</p>
          </div>

          <div :if={@rooms != []} class="conversation-list">
            <.link
              :for={entry <- @rooms}
              navigate={~p"/rooms/#{entry.room.id}"}
              class="conversation-row"
              aria-label={"Open #{entry.room.type} conversation #{entry.title}"}
            >
              <div class="conversation-avatar">
                <img
                  :if={entry.peer && entry.peer.avatar_url}
                  src={entry.peer.avatar_url}
                  alt=""
                  loading="lazy"
                />
                <span :if={!entry.peer || !entry.peer.avatar_url}>{initial(entry.title)}</span>
              </div>
              <div class="conversation-person">
                <strong>{entry.title}</strong>
                <span>{entry.subtitle}</span>
              </div>
              <div class="conversation-meta">
                <span class="private-label">{if entry.room.type == "group",
                  do: "Group",
                  else: "Private"}</span>
                <span>{activity_time(@room_activity[entry.room.id] || entry.member.inserted_at)}</span>
                <span :if={Map.get(@unread_counts, entry.room.id, 0) > 0} class="unread-badge">
                  {Map.get(@unread_counts, entry.room.id)}
                </span>
              </div>
              <.icon name="hero-arrow-up-right" class="size-4 text-base-content/35" />
            </.link>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    rooms = Rooms.list_rooms(scope)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ChatApp.PubSub, "user:#{scope.user.id}")
    end

    {:ok,
     socket
     |> assign(:rooms, rooms)
     |> assign(:room_activity, %{})
     |> assign(:unread_counts, unread_counts(scope, rooms))
     |> assign(:search_form, to_form(%{"username" => ""}, as: "room"))
     |> assign(:search_error, nil)
     |> assign(:group_form, to_form(%{"name" => ""}, as: "group"))
     |> assign(:group_error, nil)}
  end

  @impl true
  def handle_event("validate_username", %{"room" => params}, socket) do
    {:noreply,
     socket |> assign(:search_error, nil) |> assign(:search_form, to_form(params, as: "room"))}
  end

  def handle_event("start_conversation", %{"room" => %{"username" => username}}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, user} <- Rooms.find_user_by_username(scope, username),
         {:ok, room} <- Rooms.create_private_room(scope, user.id) do
      {:noreply, push_navigate(socket, to: ~p"/rooms/#{room.id}")}
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :search_error,
           "We couldn't find that username. Check the spelling and try again."
         )}
    end
  end

  def handle_event("create_group", %{"group" => %{"name" => name}}, socket) do
    case Rooms.create_group_room(socket.assigns.current_scope, name) do
      {:ok, room} ->
        {:noreply, push_navigate(socket, to: ~p"/rooms/#{room.id}")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:group_error, "Choose a group name between 1 and 120 characters.")
         |> assign(:group_form, to_form(%{"name" => name}, as: "group"))}
    end
  end

  @impl true
  def handle_info({:room_activity, room_id, at}, socket) do
    room_activity = Map.put(socket.assigns.room_activity, room_id, at)

    rooms =
      socket.assigns.current_scope
      |> Rooms.list_rooms()
      |> Enum.sort_by(
        fn entry ->
          (room_activity[entry.room.id] || entry.member.inserted_at)
          |> DateTime.to_unix(:microsecond)
        end,
        :desc
      )

    {:noreply,
     socket
     |> assign(:rooms, rooms)
     |> assign(:unread_counts, unread_counts(socket.assigns.current_scope, rooms))
     |> assign(:room_activity, room_activity)}
  end

  def handle_info({:room_cursor_updated, room_id}, socket) do
    count = unread_count(socket.assigns.current_scope, room_id)

    {:noreply,
     assign(socket, :unread_counts, Map.put(socket.assigns.unread_counts, room_id, count))}
  end

  def handle_info({:room_revoked, _room_id}, socket), do: {:noreply, refresh_rooms(socket)}

  def handle_info({:relationship_changed, _other_user_id}, socket) do
    {:noreply, refresh_rooms(socket)}
  end

  defp initial(name), do: name |> String.trim() |> String.first() |> String.upcase()

  defp activity_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d")

  defp refresh_rooms(socket) do
    rooms = Rooms.list_rooms(socket.assigns.current_scope)

    socket
    |> assign(:rooms, rooms)
    |> assign(:unread_counts, unread_counts(socket.assigns.current_scope, rooms))
  end

  defp unread_counts(scope, rooms) do
    Map.new(rooms, &{&1.room.id, unread_count(scope, &1.room.id)})
  end

  defp unread_count(scope, room_id) do
    case Messaging.unread_count(scope, room_id) do
      {:ok, count} -> count
      _ -> 0
    end
  end
end
