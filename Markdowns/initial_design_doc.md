# Real-Time Chat Application
## Technical Design Document & Phase-Wise Implementation Plan

**Architecture:** Elixir + Phoenix LiveView + PostgreSQL + MongoDB  
**Project Type:** Real-time messaging application  
**Version:** 2.0

---

# 1. Project Overview

## 1.1 Objective

Build a real-time chat application supporting private one-to-one conversations and group chatrooms.

The application will allow users to communicate instantly, view conversation history, track message delivery and read status, and see the online presence of other users.

The project will use Elixir and the Phoenix framework to explore concurrent programming, fault tolerance, real-time communication and distributed systems.

It will use a hybrid database architecture combining PostgreSQL and MongoDB.

## 1.2 Project Goals

The primary goals are:

1. Build a reliable real-time messaging application.
2. Understand Elixir's concurrency model and OTP.
3. Learn Phoenix LiveView and PubSub.
4. Design a hybrid relational and NoSQL data architecture.
5. Implement secure authentication and authorization.
6. Handle concurrent users and simultaneous message delivery.
7. Implement reliable message persistence and synchronization.
8. Learn how real-time applications can scale across multiple server instances.

## 1.3 Scope

### Initial features

- User registration and login.
- User profiles.
- One-to-one private conversations.
- Group chatroom creation.
- Group membership management.
- Real-time message delivery.
- Message history and pagination.
- Online/offline presence.
- Typing indicators.
- Message delivery acknowledgements.
- Read receipts.
- Reconnection and message synchronization.
- Basic user and room management.

### Future features

- Image and file sharing.
- Push notifications.
- Message editing and deletion.
- Message search.
- Message reactions.
- End-to-end encryption.
- Multi-device synchronization.
- Advanced moderation.
- Distributed deployment.

---

# 2. Technology Stack

| Component | Technology | Responsibility |
|---|---|---|
| Programming language | Elixir | Backend application logic |
| Web framework | Phoenix | HTTP and application framework |
| Interactive UI | Phoenix LiveView | Real-time browser interface |
| Concurrency | BEAM / OTP | Lightweight processes and fault tolerance |
| Communication | Phoenix PubSub | Real-time event broadcasting |
| Relational database | PostgreSQL | Users, rooms, memberships and sessions |
| NoSQL database | MongoDB | Messages and message-related data |
| ORM / query layer | Ecto | PostgreSQL data access |
| Background jobs | Oban | Asynchronous and scheduled tasks |
| Frontend styling | Tailwind CSS | UI styling |
| Testing | ExUnit | Backend testing |
| Browser testing | Playwright | End-to-end testing |
| Containerization | Docker | Reproducible development environment |
| Version control | Git | Source control |

## 2.1 Why Elixir and Phoenix?

Elixir runs on the BEAM virtual machine, which was designed for highly concurrent and fault-tolerant applications.

Important capabilities include:

- Lightweight processes.
- Message passing.
- Process isolation.
- Supervision trees.
- Asynchronous execution.
- Distributed node communication.

Phoenix provides the web application framework, while LiveView enables interactive browser interfaces without requiring us to build a separate JavaScript WebSocket client for every real-time feature.

## 2.2 Why Phoenix LiveView?

LiveView allows the server to maintain interactive UI state and send incremental updates to connected browsers.

For our application:

- A user sends a message through a LiveView event.
- The server validates and persists the message.
- Phoenix PubSub broadcasts the event.
- Connected LiveView processes update their respective interfaces.

We will use Phoenix PubSub as the internal broadcasting mechanism.

Phoenix Channels are not required for the initial browser application. They remain an option for future mobile clients or independent WebSocket consumers.

## 2.3 Why use two databases?

The application has two different data requirements.

**PostgreSQL:**

- Structured relational information.
- Foreign key relationships.
- Unique constraints.
- Transactions.
- Authorization-related data.
- Background job persistence.

**MongoDB:**

- High-volume message documents.
- Flexible message payloads.
- Conversation-based queries.
- Message metadata.
- Delivery and read-receipt records.

The databases will have clearly separated responsibilities. We will not maintain duplicate authoritative copies of the same data in both databases.

---

# 3. High-Level Architecture

```text
                    Browser
                       |
                       |
                Phoenix LiveView
                       |
                Phoenix Endpoint
                       |
                 LiveView Events
                       |
                Application Contexts
                       |
          +------------+-------------+
          |                          |
      PostgreSQL                 MongoDB
          |                          |
    Users and Rooms              Messages
    Memberships                   Receipts
    Permissions                    History
    Sessions
    Oban Jobs
          |
          |
     Phoenix PubSub
          |
          |
    Connected LiveViews
          |
          |
     Real-time UI updates
```

## 3.1 Architectural Style

We will use a **modular monolith**.

The application will initially run as one Phoenix application, with functionality divided into independent contexts.

We will not start with microservices because they introduce unnecessary infrastructure and distributed communication complexity.

Our modular design will allow us to extract components into separate services later if there is a genuine scaling requirement.

## 3.2 Main Application Components

### Authentication Context

Responsible for:

- Registration.
- Login.
- Logout.
- Password hashing.
- Session validation.
- Account management.

### Accounts Context

Responsible for:

- User profiles.
- User lookup.
- Profile updates.

### Rooms Context

Responsible for:

- Creating private conversations.
- Creating group rooms.
- Managing room membership.
- Managing administrators.
- Enforcing room permissions.

### Messaging Context

Responsible for:

- Creating messages.
- Retrieving message history.
- Editing and deleting messages.
- Message pagination.
- Delivery and read status.

### Presence Context

Responsible for:

- Online users.
- Offline users.
- Multiple connected sessions.
- Presence tracking.

### Notifications Context

Responsible for:

- Background notifications.
- Email notifications.
- Scheduled jobs.
- Future push notifications.

---

# 4. Database Architecture

This is one of the most important architectural decisions.

We will use PostgreSQL and MongoDB for different types of information.

## 4.1 PostgreSQL — Relational Data

PostgreSQL will be the authoritative source for:

- Users.
- User sessions.
- Chatrooms.
- Room memberships.
- Room permissions.
- Room metadata.
- Background jobs.

### Users table

| Column | Type | Description |
|---|---|---|
| id | UUID | Primary key |
| username | VARCHAR | Unique username |
| email | VARCHAR | Unique email |
| password_hash | VARCHAR | Hashed password |
| display_name | VARCHAR | Display name |
| avatar_url | TEXT | Profile image |
| inserted_at | TIMESTAMP | Creation time |
| updated_at | TIMESTAMP | Last update |

Password hashes will use a secure password hashing algorithm such as Argon2id. Passwords will never be stored in plaintext.

### Sessions table

| Column | Type | Description |
|---|---|---|
| id | UUID | Primary key |
| user_id | UUID | Associated user |
| token_hash | VARCHAR | Hashed session token |
| expires_at | TIMESTAMP | Expiration |
| inserted_at | TIMESTAMP | Creation time |

The session table will be used for server-side session management.

### Rooms table

| Column | Type | Description |
|---|---|---|
| id | UUID | Primary key |
| name | VARCHAR | Room name |
| type | ENUM | private / group |
| created_by | UUID | Creator |
| inserted_at | TIMESTAMP | Creation time |
| updated_at | TIMESTAMP | Last update |

For private conversations, room identity will be independent of the two participants' ordering.

We will enforce one private conversation per pair of users using a normalized participant-pair representation or a unique canonical conversation key.

### Room Members table

| Column | Type | Description |
|---|---|---|
| id | UUID | Primary key |
| room_id | UUID | Associated room |
| user_id | UUID | Associated user |
| role | VARCHAR | owner / admin / member |
| joined_at | TIMESTAMP | Join time |
| left_at | TIMESTAMP | Leave time |

Constraints:

- A user should not have duplicate active membership in a room.
- Room membership must reference an existing user and room.
- A private conversation must have exactly two participants.
- Group administrators must have permission to manage members.

### PostgreSQL Indexes

We will add indexes for frequently accessed fields.

- `users(username)` — unique.
- `users(email)` — unique.
- `sessions(user_id)`.
- `sessions(token_hash)` — unique.
- `sessions(expires_at)`.
- `rooms(created_by)`.
- `room_members(room_id, user_id)` — unique for active membership.
- `room_members(user_id, room_id)`.
- `rooms(private_pair_key)` — unique for private conversations.

The exact membership uniqueness implementation will account for historical memberships and the database's handling of nullable `left_at` values.

## 4.2 MongoDB — Message Data

MongoDB will store:

- Messages.
- Message delivery records.
- Read receipts.
- Message-related metadata.

Messages will be separate documents rather than embedded inside room documents.

### Messages collection

Example document:

```json
{
  "_id": "message_uuid",
  "room_id": "room_uuid",
  "sender_id": "user_uuid",
  "client_message_id": "client_generated_uuid",
  "type": "text",
  "content": {
    "text": "Hello everyone!"
  },
  "created_at": "2026-11-23T12:00:00Z",
  "edited_at": null,
  "deleted_at": null
}
```

### Message fields

| Field | Purpose |
|---|---|
| _id | Unique message identifier |
| room_id | Conversation identifier |
| sender_id | Message sender |
| client_message_id | Client-generated idempotency key |
| type | Text, image, file, etc. |
| content | Message payload |
| created_at | Message creation time |
| edited_at | Last edit time |
| deleted_at | Soft deletion timestamp |

### Message indexes

- `(room_id, created_at, _id)` — conversation history.
- `(room_id, sender_id, client_message_id)` — unique idempotency constraint.
- `(sender_id, created_at)` — sender history where needed.

We will use a deterministic ordering strategy using creation timestamps and message IDs as a tie-breaker.

For higher message volumes, we can introduce a room-level sequence number later.

### Message receipts collection

Example:

```json
{
  "_id": "receipt_uuid",
  "message_id": "message_uuid",
  "room_id": "room_uuid",
  "user_id": "recipient_uuid",
  "status": "delivered",
  "delivered_at": "2026-11-23T12:00:05Z",
  "read_at": null
}
```

Indexes:

- `(message_id, user_id)` — unique.
- `(room_id, user_id, status)`.
- `(user_id, delivered_at)` where useful.

For group messages, receipt records will be created for recipients when needed. We will not create receipt records for every possible recipient until the application requires them.

## 4.3 Database Ownership Rules

To prevent inconsistencies:

| Data | Authoritative database |
|---|---|
| User information | PostgreSQL |
| Authentication sessions | PostgreSQL |
| Room information | PostgreSQL |
| Room membership | PostgreSQL |
| Room permissions | PostgreSQL |
| Message content | MongoDB |
| Message delivery status | MongoDB |
| Message read receipts | MongoDB |
| Background job records | PostgreSQL through Oban |

MongoDB will store user and room UUIDs as references, not as foreign keys.

This means application-level validation is required before accepting messages or changing room-related data.

## 4.4 Cross-Database Consistency

PostgreSQL and MongoDB do not share a normal atomic transaction.

We must avoid assuming that a transaction in one database also commits the other database.

Our initial approach:

1. Validate user and room membership in PostgreSQL.
2. Persist the message in MongoDB.
3. Broadcast the persisted message through Phoenix PubSub.
4. Return an acknowledgement to the sender.
5. Allow clients to synchronize messages after reconnection.

If broadcasting fails after the MongoDB write, the message is still available in persistent history.

For stronger recovery guarantees, a future phase will introduce a durable outbox or event-recovery mechanism. We will not claim exactly-once delivery; we will use idempotency and synchronization to achieve effectively-once message creation.

---

# 5. Backend Architecture

## 5.1 Project Structure

Proposed Phoenix application structure:

```text
chat_app/
│
├── lib/
│   ├── chat_app/
│   │   ├── accounts/
│   │   │   ├── user.ex
│   │   │   └── accounts.ex
│   │   │
│   │   ├── authentication/
│   │   │   └── authentication.ex
│   │   │
│   │   ├── rooms/
│   │   │   ├── room.ex
│   │   │   ├── room_member.ex
│   │   │   └── rooms.ex
│   │   │
│   │   ├── messaging/
│   │   │   ├── message.ex
│   │   │   ├── receipt.ex
│   │   │   └── messaging.ex
│   │   │
│   │   ├── presence/
│   │   │   └── presence.ex
│   │   │
│   │   ├── notifications/
│   │   │   └── notifications.ex
│   │   │
│   │   ├── mongo.ex
│   │   └── application.ex
│   │
│   └── chat_app_web/
│       ├── controllers/
│       ├── live/
│       │   ├── auth_live/
│       │   ├── chat_live/
│       │   └── room_live/
│       ├── components/
│       ├── plugs/
│       ├── router.ex
│       └── endpoint.ex
│
├── config/
├── priv/
│   └── repo/
├── test/
├── assets/
├── docker-compose.yml
├── mix.exs
└── README.md
```

We will organize code by business context rather than putting all database queries and event handlers in one large module.

## 5.2 Ecto and MongoDB Access

Ecto will manage PostgreSQL schemas, queries, changesets and migrations.

MongoDB access will use a MongoDB-compatible Elixir driver, such as the official community-supported `mongodb_driver` ecosystem.

We will keep MongoDB queries behind the Messaging context so LiveView modules do not directly depend on database implementation details.

Example conceptual API:

```elixir
Messaging.create_message(attrs)
Messaging.list_messages(room_id, cursor)
Messaging.mark_as_read(message_id, user_id)
Messaging.delete_message(message_id, user_id)
```

The rest of the application should not need to know whether a message is stored in MongoDB or another database.

---

# 6. Phoenix LiveView Architecture

## 6.1 Why LiveView?

LiveView allows us to build interactive interfaces using server-side Elixir logic.

The browser maintains a persistent connection to the Phoenix server. User events are sent to the server, and the server sends incremental UI updates.

This is useful for:

- Message sending.
- Receiving messages.
- Typing indicators.
- Online presence.
- Read receipts.
- Room updates.

## 6.2 Main LiveViews

### Authentication LiveViews

- LoginLive
- RegistrationLive

### Chat LiveViews

- ChatLive.Index
- ChatLive.Show
- ChatLive.Private
- ChatLive.Group

### Room LiveViews

- RoomLive.Create
- RoomLive.Settings
- RoomLive.Members

## 6.3 Message Sending Flow

```text
User types message
       |
       v
LiveView handle_event
       |
       v
Validate message
       |
       v
Check room membership
       |
       v
Messaging context
       |
       v
Persist in MongoDB
       |
       v
Broadcast through Phoenix PubSub
       |
       v
Connected LiveViews receive event
       |
       v
UI updates
```

We will persist messages before broadcasting them.

This ensures a message is not presented as successfully stored before the database write succeeds.

## 6.4 PubSub Topics

We will use room-specific topics.

Example:

```text
room:<room_uuid>
```

When a user opens a room:

1. The server authenticates the user.
2. The server checks room membership.
3. The LiveView subscribes to the room topic.
4. New messages are broadcast to the topic.
5. Connected users receive updates.

Private conversations use the same mechanism, but membership validation ensures only the two participants can subscribe.

---

# 7. Authentication and Security

## 7.1 Authentication

We will implement server-side session authentication.

Flow:

1. User submits credentials.
2. Server verifies the password hash.
3. Server creates a cryptographically secure session token.
4. Only a hash of the token is stored in PostgreSQL.
5. The raw token is sent in a secure, HTTP-only cookie.
6. Subsequent requests validate the session.

Cookie configuration:

- HttpOnly enabled.
- Secure enabled in production.
- Appropriate SameSite policy.
- Restricted path and domain.
- Session expiration.
- Session invalidation on logout.

## 7.2 Protected Routes

Authenticated LiveViews will use Phoenix authentication plugs and LiveView lifecycle authentication.

We will distinguish between:

- Authentication: Is the user logged in?
- Authorization: Is the user allowed to access this resource?

A user being logged in does not mean they can access every room.

## 7.3 Room Authorization

Every room-related operation must validate membership and permissions on the server.

Examples:

- A user cannot join a private conversation they are not part of.
- A user cannot read messages from an unrelated room.
- A normal member cannot remove administrators.
- Only authorized users can modify room settings.

Authorization will be checked when subscribing and when performing sensitive actions, not only when rendering the initial page.

## 7.4 Additional Security

- Password hashing with Argon2id.
- Input validation.
- Rate limiting.
- CSRF protection.
- Secure cookies.
- Protection against unauthorized message access.
- Safe handling of user-generated content.
- File upload validation in a future phase.
- No sensitive information in logs.

---

# 8. Message Event Design

We will define a consistent event contract.

## 8.1 Client-to-Server Events

| Event | Purpose |
|---|---|
| send_message | Send a message |
| typing_started | Indicate typing |
| typing_stopped | Stop typing indicator |
| mark_read | Mark messages as read |
| load_history | Retrieve older messages |
| edit_message | Edit an existing message |
| delete_message | Delete a message |

In LiveView, these will primarily be implemented as `handle_event/3` events rather than manually managed WebSocket event names.

## 8.2 Server-to-Client Events

| Event | Purpose |
|---|---|
| new_message | New message available |
| message_updated | Message edited |
| message_deleted | Message deleted |
| user_joined | User joined room |
| user_left | User left room |
| typing_update | Typing status changed |
| message_delivered | Delivery acknowledged |
| message_read | Read status updated |

These events will be broadcast through Phoenix PubSub and handled by subscribed LiveViews.

## 8.3 Message Acknowledgement

The sender will receive an acknowledgement containing:

- Message ID.
- Room ID.
- Server creation timestamp.
- Persistence status.

The sender's UI should distinguish between:

- Sending.
- Sent.
- Failed.

Delivery and read status will be updated separately.

## 8.4 Idempotency

The client will generate a unique `client_message_id` for every outgoing message.

MongoDB will enforce a unique constraint on the sender and client message ID within the room.

If a client retries because of a timeout, the server should return the existing message rather than creating a duplicate.

This is essential when reconnecting or handling temporary network failures.

---

# 9. Message History and Synchronization

Message history will be loaded using cursor-based pagination.

We will not use offset pagination for large conversations because it becomes inefficient as data grows and messages are inserted.

Example:

```text
GET messages before cursor
       |
       v
Query MongoDB
       |
       v
Sort by created_at and _id
       |
       v
Return next page
```

The client will retain a synchronization cursor.

When reconnecting:

1. Re-establish the LiveView connection.
2. Revalidate authentication and room membership.
3. Request messages newer than the last synchronized cursor.
4. Merge messages using their unique IDs.
5. Resume live updates.

The database remains the source of truth, not the client's local UI state.

---

# 10. Presence and Typing Indicators

## 10.1 Phoenix Presence

We will use Phoenix Presence to track:

- Online users.
- Active sessions.
- Users currently viewing a room.
- Presence changes.

A user may have multiple active connections.

The application should show a user as online while at least one valid presence session remains active.

Presence will not be treated as permanent database state.

## 10.2 Typing Indicators

Typing events will be temporary.

We will:

- Broadcast typing_started.
- Broadcast typing_stopped.
- Expire stale typing indicators.
- Avoid persisting typing events.
- Rate-limit repeated typing notifications.

Typing events should not generate unnecessary database writes.

---

# 11. Background Jobs

We will use Oban with PostgreSQL for persistent background processing.

Potential jobs:

- Email notifications.
- Push notifications.
- Scheduled cleanup.
- Account maintenance.
- Expiring old sessions.
- Retrying notification delivery.

Oban will not be responsible for the primary synchronous message-persistence path.

We will avoid adding jobs where a simple synchronous operation is more reliable.

---

# 12. OTP and Supervision Architecture

A major learning objective is understanding OTP.

Our application supervision tree will initially look conceptually like this:

```text
ChatApp.Application
│
├── ChatApp.Repo
│
├── MongoDB Connection
│
├── Phoenix.PubSub
│
├── Phoenix.Presence
│
├── Oban
│
└── Phoenix.Endpoint
```

We will study:

### Processes

Lightweight independent execution units managed by the BEAM.

### GenServer

A behaviour for implementing stateful server processes.

### Supervisors

Processes that monitor and restart child processes.

### Supervision strategies

- One-for-one.
- One-for-all.
- Rest-for-one.

We will not create unnecessary GenServers for every user or room. We will use existing Phoenix abstractions unless custom process state is genuinely needed.

---

# 13. Error Handling and Reliability

We need to account for failures at different stages.

| Failure | Expected behaviour |
|---|---|
| MongoDB unavailable | Message write fails; sender sees failure |
| PostgreSQL unavailable | Authentication and room authorization cannot safely proceed |
| PubSub broadcast fails | Persisted message remains available through history synchronization |
| Browser disconnects | Reconnect and synchronize missing messages |
| Duplicate send | Idempotency prevents duplicate message creation |
| Unauthorized room access | Reject operation |
| Server process crashes | OTP supervision restarts supervised processes |
| Background job fails | Oban retry policy handles eligible jobs |

We will not rely on reconnection alone to guarantee message delivery.

Clients must always be able to recover their state from persistent message history.

---

# 14. Phase-Wise Implementation Plan

We will implement the project in small, testable phases.

## Phase 0 — Development Environment

**Objective:** Set up the complete development environment.

Tasks:

- Install Elixir and Erlang/OTP.
- Install Phoenix.
- Install Node.js for frontend assets.
- Set up PostgreSQL.
- Set up MongoDB.
- Create Docker Compose configuration.
- Generate Phoenix application.
- Initialize Git repository.
- Configure environment variables.

Expected output:

- Phoenix application starts.
- PostgreSQL connection works.
- MongoDB connection works.
- Docker services start successfully.

Concepts:

- Elixir syntax.
- Mix.
- OTP application startup.
- Phoenix project structure.

## Phase 1 — Backend and Database Foundation

**Objective:** Establish the application's core architecture.

Tasks:

- Create Ecto schemas.
- Configure PostgreSQL migrations.
- Define users, rooms and memberships.
- Configure MongoDB driver.
- Create message and receipt collections.
- Add indexes.
- Implement database health checks.
- Create initial context modules.

Expected output:

- Both databases connect.
- PostgreSQL migrations work.
- MongoDB CRUD operations work.
- Database access is separated from application logic.

Concepts:

- Ecto.
- Changesets.
- MongoDB document modelling.
- Database indexing.
- Modular architecture.

## Phase 2 — Authentication and Sessions

**Objective:** Implement secure user authentication.

Tasks:

- Registration.
- Login.
- Logout.
- Password hashing.
- Server-side sessions.
- Secure cookies.
- Session expiration.
- Protected LiveViews.

Expected output:

Users can securely register, log in and access authenticated pages.

Concepts:

- Plug.
- Authentication.
- Authorization.
- Session management.
- Secure cookie handling.

## Phase 3 — Room Management

**Objective:** Implement private and group conversations.

Tasks:

- Create private conversations.
- Create group rooms.
- Add room members.
- Remove room members.
- Implement administrator permissions.
- Prevent unauthorized access.
- Add room listing and user search.

Expected output:

Users can create private chats and group rooms.

Concepts:

- Relational modelling.
- Ecto associations.
- Database constraints.
- Authorization policies.

## Phase 4 — Phoenix LiveView Integration

**Objective:** Establish interactive chat interfaces.

Tasks:

- Create ChatLive.
- Implement room navigation.
- Connect authenticated LiveViews.
- Implement event handlers.
- Subscribe to PubSub topics.
- Handle connection lifecycle.

Expected output:

Users can open a room and interact with its interface without manually building a frontend WebSocket layer.

Concepts:

- LiveView lifecycle.
- handle_event.
- handle_info.
- Phoenix PubSub.
- Process communication.

## Phase 5 — Real-Time Messaging

**Objective:** Implement the primary messaging workflow.

Tasks:

- Send text messages.
- Validate message content.
- Verify room membership.
- Persist messages in MongoDB.
- Broadcast messages through PubSub.
- Acknowledge sender.
- Handle failed writes.
- Implement idempotency.

Expected output:

Two users can exchange messages in real time, and messages are persisted.

This is our first major end-to-end milestone.

## Phase 6 — Message History

**Objective:** Implement persistent conversation history.

Tasks:

- Retrieve messages.
- Cursor-based pagination.
- Load older messages.
- Synchronize missed messages.
- Handle duplicate events.
- Preserve ordering.

Expected output:

Users can reopen conversations and see previous messages.

Concepts:

- Pagination.
- Data synchronization.
- Idempotency.
- Event ordering.

## Phase 7 — Presence and Typing

**Objective:** Add real-time user activity information.

Tasks:

- Phoenix Presence.
- Online/offline status.
- Multiple active sessions.
- Room presence.
- Typing indicators.
- Stale presence cleanup.

Expected output:

Users can see online participants and typing activity.

Concepts:

- Presence tracking.
- Distributed process state.
- PubSub.
- Ephemeral events.

## Phase 8 — Delivery and Read Receipts

**Objective:** Track message delivery and reading.

Tasks:

- Delivery acknowledgements.
- Read receipts.
- Per-user receipt tracking.
- Group read status.
- Unread message counts.
- Receipt synchronization.

Expected output:

Users can distinguish sent, delivered and read messages.

Concepts:

- Event consistency.
- State transitions.
- Concurrent updates.

## Phase 9 — Testing and Integration

**Objective:** Validate the complete application.

Tasks:

- Unit tests.
- Integration tests.
- LiveView tests.
- Database tests.
- Authorization tests.
- Duplicate message tests.
- Reconnection tests.
- Multi-user tests.
- Browser end-to-end tests.

Expected output:

A stable application with verified core functionality.

## Phase 10 — Production Readiness

**Objective:** Prepare the application for deployment.

Tasks:

- Production configuration.
- Docker image.
- Database backup strategy.
- Secrets management.
- Structured logging.
- Health checks.
- Monitoring.
- Error tracking.
- Deployment configuration.

Expected output:

A deployable application with basic operational visibility.

## Phase 11 — Distributed Systems and Scaling

**Objective:** Explore production-scale architecture.

Topics:

- Multiple Phoenix nodes.
- Distributed PubSub.
- Node clustering.
- Horizontal scaling.
- Load balancing.
- Message ordering.
- Durable event recovery.
- Outbox patterns.
- Backpressure.
- Rate limiting.
- Connection scaling.
- Observability with OpenTelemetry.

This phase is deliberately separated from the first working implementation.

---

# 15. Testing Strategy

We will test functionality at multiple levels.

## Unit Testing

Test individual contexts and functions:

- Password verification.
- Message validation.
- Room authorization.
- Message creation.
- Receipt updates.

## Integration Testing

Test interaction between components:

- PostgreSQL and Accounts.
- PostgreSQL and Rooms.
- MongoDB and Messaging.
- Messaging and PubSub.
- Authentication and LiveView.

## End-to-End Testing

Test actual user workflows:

**Scenario 1: Private chat**

1. Alice registers.
2. Bob registers.
3. Alice opens a private conversation with Bob.
4. Alice sends a message.
5. Bob receives it instantly.
6. Bob replies.
7. Alice receives the reply.

**Scenario 2: Group chat**

1. Alice creates a group.
2. Alice adds Bob and Charlie.
3. Bob sends a message.
4. Alice and Charlie receive it.
5. Charlie reads the message.
6. The receipt is updated.

**Scenario 3: Reconnection**

1. Alice sends a message.
2. Bob disconnects.
3. Alice sends another message.
4. Bob reconnects.
5. Bob synchronizes missed messages.
6. No duplicate messages appear.

---

# 16. Important Architectural Decisions

| Decision | Reason |
|---|---|
| Modular monolith | Easier development and testing |
| Elixir + Phoenix | Concurrency and fault tolerance |
| Phoenix LiveView | Server-driven real-time browser UI |
| Phoenix PubSub | Real-time event distribution |
| PostgreSQL | Relational data and transactions |
| MongoDB | Message document storage |
| Oban | Persistent background jobs |
| Server-side sessions | Secure session control |
| Cursor pagination | Efficient message history |
| Client-generated IDs | Duplicate prevention |
| Database-first messaging | Persistence before broadcast |
| OTP supervision | Process recovery |

## Architectural Constraints

- PostgreSQL and MongoDB do not share atomic transactions.
- PubSub is not a durable message queue.
- LiveView connections consume server-side resources.
- Presence is temporary state, not permanent user data.
- A successful broadcast does not prove that every recipient received the message.
- A single Phoenix instance is not a distributed system.
- Horizontal scaling requires explicit planning for distributed PubSub and database connections.

---

# 17. Initial Project Milestone

We should not implement every feature before validating the architecture.

Our first vertical slice will be:

1. Alice and Bob register.
2. Both log in.
3. Alice creates a private conversation with Bob.
4. Both open the conversation.
5. Alice sends a message.
6. The message is persisted in MongoDB.
7. Bob receives the message through Phoenix PubSub and LiveView.
8. Bob refreshes the browser.
9. The message is retrieved from MongoDB.

This proves the most important parts of the architecture:

- Authentication.
- PostgreSQL integration.
- MongoDB integration.
- Room authorization.
- LiveView.
- PubSub.
- Message persistence.
- Message history.

Once this works, we can add group chats, presence, receipts and more advanced reliability features.

---

# 18. Final Project Outcome

At completion, the application should demonstrate:

- A working private and group messaging platform.
- A backend built with Elixir and Phoenix.
- Interactive interfaces powered by LiveView.
- Relational and NoSQL database integration.
- Secure authentication and authorization.
- Real-time communication through PubSub.
- OTP-based fault-tolerant application structure.
- Reliable message persistence and synchronization.
- Testing and deployment practices.
- An understanding of the fundamentals of distributed messaging systems.

**Core engineering principle:** Build a correct, persistent and recoverable messaging system first. Optimize for massive scale only after the basic system works reliably.
