defmodule ChatApp.Messaging do
  @moduledoc "Persistent, ordered room messages stored in MongoDB."

  alias ChatApp.Accounts.{Scope, User}
  alias ChatApp.Blocking
  alias ChatApp.Rooms

  @messages "messages"
  @counters "room_message_counters"
  @default_limit 50
  @max_limit 100

  def ensure_indexes do
    Mongo.create_indexes(ChatApp.Mongo, @messages, [
      [key: [room_id: 1, seq: 1], name: "room_sequence_unique", unique: true],
      [
        key: [room_id: 1, sender_id: 1, client_message_id: 1],
        name: "room_sender_client_message_unique",
        unique: true
      ]
    ])
  end

  def send_message(
        %Scope{user: %User{id: sender_id} = user} = scope,
        room_id,
        client_message_id,
        content
      )
      when is_binary(room_id) and is_binary(client_message_id) and is_binary(content) do
    with {:ok, client_message_id} <- Ecto.UUID.cast(client_message_id),
         {:ok, {room, _membership}} <- Rooms.get_room_for_user(scope, room_id),
         :ok <- ensure_not_blocked(room, sender_id),
         :ok <- validate_content(content) do
      case find_by_client_id(room.id, sender_id, client_message_id) do
        {:ok, message} -> {:ok, message}
        :not_found -> persist_message(room.id, user, client_message_id, content)
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :invalid_client_message_id}
      {:error, _} = error -> error
    end
  end

  def send_message(_scope, _room_id, _client_message_id, _content), do: {:error, :not_authorized}

  def list_recent_messages(scope, room_id, limit \\ @default_limit)

  def list_recent_messages(%Scope{} = scope, room_id, limit) do
    list_messages(scope, room_id, %{}, :desc, limit)
  end

  def list_recent_messages(_scope, _room_id, _limit), do: {:error, :not_authorized}

  def list_messages_before(scope, room_id, before_seq, limit \\ @default_limit)

  def list_messages_before(%Scope{} = scope, room_id, before_seq, limit)
      when is_integer(before_seq) and before_seq > 0 do
    list_messages(scope, room_id, %{seq: %{"$lt" => before_seq}}, :desc, limit)
  end

  def list_messages_before(_scope, _room_id, _before_seq, _limit), do: {:error, :invalid_sequence}

  def list_messages_after(scope, room_id, after_seq, limit \\ @default_limit)

  def list_messages_after(%Scope{} = scope, room_id, after_seq, limit)
      when is_integer(after_seq) and after_seq >= 0 do
    list_messages(scope, room_id, %{seq: %{"$gt" => after_seq}}, :asc, limit)
  end

  def list_messages_after(_scope, _room_id, _after_seq, _limit), do: {:error, :invalid_sequence}

  def latest_sequence(room_id) when is_binary(room_id) do
    case Mongo.find_one(ChatApp.Mongo, @counters, %{"_id" => room_id}) do
      nil -> {:ok, 0}
      {:error, reason} -> {:error, reason}
      counter -> {:ok, field(counter, :seq) || 0}
    end
  end

  def latest_sequence(_room_id), do: {:error, :invalid_room_id}

  def unread_count(%Scope{user: %User{id: user_id}} = scope, room_id) do
    with {:ok, {room, membership}} <- Rooms.get_room_for_user(scope, room_id),
         false <- private_room_blocked?(room, user_id),
         {:ok, count} <-
           Mongo.count(ChatApp.Mongo, @messages, %{
             room_id: room_id,
             seq: %{"$gt" => membership.last_read_seq},
             sender_id: %{"$ne" => user_id},
             created_at: %{"$gte" => membership.joined_at},
             deleted_at: nil
           }) do
      {:ok, count}
    else
      true -> {:ok, 0}
      {:error, _} = error -> error
    end
  end

  def unread_count(_scope, _room_id), do: {:error, :not_authorized}

  defp list_messages(scope, room_id, sequence_filter, direction, limit) do
    with {:ok, {_room, membership}} <- Rooms.get_room_for_user(scope, room_id) do
      filter =
        Map.merge(sequence_filter, %{
          room_id: room_id,
          created_at: %{"$gte" => membership.joined_at}
        })

      sort = if direction == :asc, do: [seq: 1], else: [seq: -1]

      case Mongo.find(ChatApp.Mongo, @messages, filter, sort: sort, limit: clamp_limit(limit)) do
        %Mongo.Stream{} = cursor ->
          messages = Enum.map(cursor, &normalize_message/1)
          {:ok, if(direction == :desc, do: Enum.reverse(messages), else: messages)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp persist_message(room_id, user, client_message_id, content) do
    message_id = Ecto.UUID.generate()
    created_at = DateTime.utc_now(:millisecond)

    result =
      Mongo.transaction(
        ChatApp.Mongo,
        fn opts ->
          session = Keyword.fetch!(opts, :session)

          with {:ok, counter} <-
                 Mongo.find_one_and_update(
                   ChatApp.Mongo,
                   @counters,
                   %{"_id" => room_id},
                   %{"$inc" => %{seq: 1}},
                   upsert: true,
                   return_document: :after,
                   session: session
                 ),
               seq when is_integer(seq) <- field(counter.value, :seq),
               message <- %{
                 _id: message_id,
                 room_id: room_id,
                 sender_id: user.id,
                 sender_name: user.display_name,
                 client_message_id: client_message_id,
                 seq: seq,
                 type: "text",
                 content: %{text: content},
                 body: content,
                 created_at: created_at,
                 edited_at: nil,
                 deleted_at: nil
               },
               {:ok, _} <- Mongo.insert_one(ChatApp.Mongo, @messages, message, session: session) do
            {:ok, message}
          else
            {:error, reason} -> {:error, reason}
            other -> {:error, {:unexpected_mongo_result, other}}
          end
        end,
        transaction_retry_timeout_s: 10
      )

    case result do
      {:ok, message} ->
        {:ok, normalize_message(message)}

      _failure ->
        case find_by_client_id(room_id, user.id, client_message_id) do
          {:ok, message} -> {:ok, message}
          :not_found -> {:error, :persistence_failed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp find_by_client_id(room_id, sender_id, client_message_id) do
    case Mongo.find_one(ChatApp.Mongo, @messages, %{
           room_id: room_id,
           sender_id: sender_id,
           client_message_id: client_message_id
         }) do
      nil -> :not_found
      {:error, reason} -> {:error, reason}
      message -> {:ok, normalize_message(message)}
    end
  end

  defp validate_content(content) do
    cond do
      String.trim(content) == "" -> {:error, :empty_message}
      String.length(content) > 4_000 -> {:error, :message_too_long}
      true -> :ok
    end
  end

  defp ensure_not_blocked(%{type: "private"} = room, user_id) do
    peer_id = if room.user_low_id == user_id, do: room.user_high_id, else: room.user_low_id
    if Blocking.blocked_between?(user_id, peer_id), do: {:error, :blocked}, else: :ok
  end

  defp ensure_not_blocked(_room, _user_id), do: :ok

  defp private_room_blocked?(%{type: "private"} = room, user_id) do
    peer_id = if room.user_low_id == user_id, do: room.user_high_id, else: room.user_low_id
    Blocking.blocked_between?(user_id, peer_id)
  end

  defp private_room_blocked?(_room, _user_id), do: false

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp_limit(_limit), do: @default_limit

  defp normalize_message(message) do
    %{
      id: field(message, :_id),
      room_id: field(message, :room_id),
      sender_id: field(message, :sender_id),
      sender_name: field(message, :sender_name),
      client_message_id: field(message, :client_message_id),
      seq: field(message, :seq),
      body: field(field(message, :content) || %{}, :text) || field(message, :body),
      status: "sent",
      inserted_at: field(message, :created_at)
    }
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp field(_map, _key), do: nil
end

defmodule ChatApp.Messaging.Indexes do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case ChatApp.Messaging.ensure_indexes() do
      :ok -> {:ok, %{ready: true}}
      {:error, reason} -> {:stop, {:mongo_indexes_unavailable, reason}}
    end
  end
end
