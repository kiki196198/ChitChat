# Real-Time Chat Application — Technical Design Document

**Version:** 3.0  
**Status:** Revised design baseline  
**Stack:** Elixir, Phoenix LiveView, PostgreSQL, MongoDB, Oban

## Change summary

This revision addresses the design review's correctness and security findings:

- Per-room monotonic message sequence replaces timestamp-based sync.
- Sequence allocation and message insertion are one MongoDB transaction.
- Connected LiveViews are revoked when membership or sessions are revoked.
- MongoDB is retained primarily as a learning objective, not because PostgreSQL is incapable of storing messages.
- Per-message/per-recipient receipts are replaced by per-user room cursors.
- Private-room and active-membership constraints are explicit.
- Phoenix generated authentication is the starting point.
- LiveView streams, per-user activity topics, and disconnected composer behaviour are defined.
- Presence is scoped; typing is ephemeral.
- Non-functional targets, deletion rules, abuse controls, Mongo test isolation, CI, and failure cases are added.
- The implementation plan starts with a complete Alice-and-Bob vertical slice.

---

# 1. Project overview

Build a real-time messaging application supporting private one-to-one conversations and group chatrooms. Users can register, authenticate, create rooms, exchange messages, retrieve history, and see presence and read status.

The project is both a working application and a learning exercise in Elixir concurrency, OTP, Phoenix LiveView, PubSub, relational/document data modelling, and distributed-systems trade-offs.

### Initial scope

- Registration, login, logout, and profiles.
- Private and group conversations.
- Membership and role management.
- Text messages, history, pagination, and reconnect synchronization.
- Real-time delivery.
- Online presence and typing indicators.
- Delivery/read cursors and unread counts.
- Basic blocking, rate limiting, and account controls.

### Later scope

File sharing, push notifications, search, reactions, advanced moderation, end-to-end encryption, multi-device improvements, and distributed deployment.

# 2. Technology stack and decisions

| Component | Technology | Responsibility |
|---|---|---|
| Language/runtime | Elixir / BEAM | Backend and concurrency |
| Web framework | Phoenix | HTTP and application framework |
| Interactive UI | Phoenix LiveView | Server-driven browser UI |
| Supervision | OTP | Process lifecycle and recovery |
| Broadcasting | Phoenix PubSub | Ephemeral real-time events |
| Relational database | PostgreSQL | Users, sessions, rooms, memberships, cursors, jobs |
| Message database | MongoDB | Message documents and room sequence counters |
| Relational data layer | Ecto | PostgreSQL queries and migrations |
| MongoDB client | `mongodb_driver` | MongoDB operations |
| Background jobs | Oban | Durable asynchronous work in PostgreSQL |
| Styling | Tailwind CSS | UI styling |
| Tests | ExUnit / Playwright | Unit, integration, browser tests |
| Local infrastructure | Docker Compose | Reproducible databases |

## 2.1 Why Elixir and Phoenix?

The BEAM provides lightweight processes, message passing, process isolation, and supervision. Phoenix provides the web framework. LiveView maintains interactive server-side UI state and sends incremental updates to browsers.

## 2.2 Why LiveView rather than React and Channels?

The initial client is a browser application. LiveView provides the browser connection and event lifecycle needed for chat. Phoenix PubSub distributes events inside the application. Channels are not required initially; they remain an option for future mobile or independent WebSocket clients.

## 2.3 Two-database ADR

**Decision:** Retain PostgreSQL and MongoDB for this learning project.

**Primary reason:** Learning to model, operate, test, and recover data across relational and document databases is an explicit project goal.

**Important qualification:** MongoDB is not required because PostgreSQL cannot support chat workloads. PostgreSQL can store messages using tables or JSONB, indexes, and partitioning. For a production application with this scope, PostgreSQL alone would likely be the simpler default.

**Costs accepted:** no cross-database foreign keys or atomic transaction; application-level consistency and reconciliation; two backup/restore paths; Mongo test isolation outside Ecto SQL Sandbox; independent failure of Mongo message writes and PostgreSQL Oban enqueues; and explicit cleanup for documents referencing deleted rooms/users.

The databases must have distinct ownership. Do not maintain two authoritative copies of the same data.

## 2.4 MongoDB topology

Run MongoDB locally as a **single-node replica set**. Transactions and change streams require a replica-set or sharded-cluster topology. The initial message sequence allocation and insert will use one transaction, so a process crash cannot commit the counter increment separately from the message.

A single-node replica set is not high availability; it is for feature compatibility and development. Verify the installed driver's exact transaction API and retry behaviour with integration tests before depending on it.

# 3. High-level architecture

```text
                         Browser
                            |
                     Phoenix Endpoint
                            |
                       Phoenix LiveView
                            |
                    Application contexts
                   /          |          \
              Accounts      Messaging    Presence
                 |              |            |
             PostgreSQL      MongoDB      Phoenix
                 |          messages +    Presence
                 |           counters
                 |              |
                 |       committed message
                 |              |
                 +---------- Messaging
                                |
                          Phoenix PubSub
                         /           \
                  room:<room_id>   user:<user_id>
                       |               |
                 Room LiveViews   Sidebar/session UI

             Oban (PostgreSQL) handles durable jobs
```

PubSub is a sibling event-distribution mechanism, not a child of PostgreSQL. Messaging broadcasts only after the MongoDB write commits.

## 3.1 Modular monolith

Start with one Phoenix application and clear context boundaries. Do not introduce microservices without a demonstrated operational need.

## 3.2 Context ownership

- **Accounts:** user profiles, account lookup/update, blocking, tombstoning.
- **Authentication:** implemented with Accounts using Phoenix's generated authentication foundation; avoid overlapping Accounts/Authentication ownership.
- **Rooms:** room creation, private-pair identity, membership history, roles, permissions.
- **Messaging:** message creation, idempotency, sequence allocation, history, pagination, edits/deletions, cursors.
- **Presence:** ephemeral presence and typing state.
- **Notifications:** Oban-backed email/push work.

# 4. Data architecture

## 4.1 PostgreSQL — authoritative relational data

PostgreSQL owns users, authentication sessions, rooms, membership history/roles, blocking relationships, per-user room cursors, and Oban jobs.

Use UUID primary keys and `timestamptz` for all timestamps. Use `citext` for case-insensitive username/email uniqueness, with an explicit normalization policy.

### Users

| Column | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| username | CITEXT | Unique |
| email | CITEXT | Unique |
| hashed_password | VARCHAR | Argon2id hash |
| display_name | VARCHAR | Public name |
| avatar_url | TEXT | Optional |
| deleted_at | TIMESTAMPTZ | Tombstone marker |
| inserted_at / updated_at | TIMESTAMPTZ | Audit timestamps |

### Sessions

| Column | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| user_id | UUID | Foreign key |
| token_hash | BYTEA/VARCHAR | SHA-256 hash of random high-entropy token |
| user_agent | TEXT | Optional, bounded |
| last_seen_at | TIMESTAMPTZ | Last activity |
| expires_at | TIMESTAMPTZ | Expiration |
| inserted_at | TIMESTAMPTZ | Creation time |

Use a cryptographically random session token. Store its SHA-256 hash; Argon2id is for passwords, not high-entropy random tokens. Renew the session on login to prevent session fixation. Logout revokes the session and disconnects its LiveView socket.

### Rooms

| Column | Type | Notes |
|---|---|---|
| id | UUID | Primary key |
| type | ENUM/constrained | `private` or `group` |
| name | VARCHAR | Nullable for private rooms |
| created_by | UUID | User foreign key |
| user_low_id | UUID | Lower UUID participant for private rooms |
| user_high_id | UUID | Higher UUID participant for private rooms |
| inserted_at / updated_at | TIMESTAMPTZ | Audit timestamps |
| deleted_at | TIMESTAMPTZ | Optional tombstone |

For private rooms, enforce `user_low_id < user_high_id` and a unique index on `(user_low_id, user_high_id)` for private-room rows. Sort participant UUIDs before insertion.

Create private rooms race-safely: `INSERT ... ON CONFLICT DO NOTHING`, then select the canonical room. Enforce exactly two participants in the transaction that creates the room and its two membership rows.

### Room memberships

| Column | Type | Notes |
|---|---|---|
| id | UUID | Primary key; one row per membership period |
| room_id | UUID | Foreign key |
| user_id | UUID | Foreign key |
| role | constrained value | `owner`, `admin`, `member` |
| joined_at | TIMESTAMPTZ | Membership start |
| left_at | TIMESTAMPTZ | Null while active |
| last_delivered_seq | BIGINT | Monotonic delivery cursor |
| last_read_seq | BIGINT | Monotonic read cursor |

Use a partial unique index:

```sql
CREATE UNIQUE INDEX room_members_one_active_membership
ON room_members (room_id, user_id)
WHERE left_at IS NULL;
```

This allows historical membership rows while preventing duplicate active membership. Use a check constraint or enum for `role`.

### Important PostgreSQL indexes

- Unique `users(username)` and `users(email)`.
- Unique `sessions(token_hash)`, plus `sessions(user_id)` and `sessions(expires_at)`.
- `rooms(created_by)`.
- Unique partial private-pair index on `(user_low_id, user_high_id)`.
- Partial unique active membership index above.
- `room_members(user_id, room_id)`.
- Indexes for blocking lookups.

## 4.2 MongoDB — message data

MongoDB owns messages and per-room sequence counters. It stores UUID references to PostgreSQL users and rooms; these are not foreign keys.

### Messages collection

```json
{
  "_id": "message-uuid",
  "room_id": "room-uuid",
  "seq": 42,
  "sender_id": "user-uuid",
  "client_message_id": "client-generated-uuid",
  "type": "text",
  "content": { "text": "Hello everyone!" },
  "created_at": "BSON Date",
  "edited_at": null,
  "deleted_at": null
}
```

Store dates as BSON Date values, not ISO strings. Choose one UUID/BSON binary representation and use it consistently. UUIDv7 may be used for IDs if the selected libraries support it consistently, but it is not the ordering authority.

### Required indexes

- Unique `(room_id, seq)` — canonical room order.
- Unique `(room_id, sender_id, client_message_id)` — idempotency.
- `(sender_id, created_at)` only if a demonstrated query needs it.

The unique idempotency index is essential. A preliminary lookup is only an optimization.

### Room counters collection

One document per room:

```json
{ "_id": "room-uuid", "seq": 42 }
```

The counter is incremented atomically in the same transaction as the message insert.

## 4.3 Ownership table

| Data | Authoritative store |
|---|---|
| User identity/profile | PostgreSQL |
| Password hash and sessions | PostgreSQL |
| Room metadata | PostgreSQL |
| Memberships/roles/permissions | PostgreSQL |
| Message content and room sequence | MongoDB |
| Read/delivery cursors | PostgreSQL membership row |
| Oban jobs | PostgreSQL |

## 4.4 Read/delivery cursors instead of receipt fan-out

Do not create one receipt document per message per recipient in v1. Each membership stores `last_delivered_seq` and `last_read_seq`.

- Both cursors only move forward.
- A message with `seq <= last_read_seq` is read by that member.
- Unread count is the number of eligible messages with `seq > last_read_seq`; do not blindly subtract cursors if messages are filtered/deleted or the member's visibility period excludes them.
- A “seen by” list is an optional projection over memberships with `last_read_seq >= message.seq`.

**Delivered definition:** the recipient's connected LiveView process received/handled the PubSub event, or the recipient advanced its delivered cursor during synchronization. It does not mean a human saw the message. Offline users become delivered after reconnect and sync.

Update cursors monotonically in PostgreSQL (e.g. `GREATEST(existing, incoming)`).

## 4.5 Ordering, idempotency, and synchronization

Timestamps are not a safe synchronization cursor under concurrent writes. A later timestamp can commit first, allowing a client to advance beyond a message that becomes visible later.

**V1 ordering authority: per-room monotonic `seq`.**

Message creation:

1. Authorize the sender's active membership in PostgreSQL.
2. Look up `(room_id, sender_id, client_message_id)`; if found, return the existing message.
3. Start a MongoDB transaction.
4. Atomically increment the room counter and obtain the new sequence.
5. Insert the message with that sequence and idempotency key.
6. Commit.
7. If the unique idempotency index reports a duplicate, abort/retry lookup and return the existing message.
8. Only after commit, broadcast the message.
9. Update sender UI state to `sent`.

The counter increment and message insert must use the same MongoDB session/transaction. Counter updates serialize competing allocations for a room. Retry transaction conflicts according to MongoDB and driver guidance.

Do not silently fall back to a separate counter update followed by insert if transaction support is unavailable. Revisit the driver/API or implement a rigorously tested serialized per-room write strategy first.

### Gaps and clients

With the transactional design, a failed transaction should not commit a sequence increment independently of the message. Gaps may still result from deliberate deletion/retention or future alternate write paths.

If a client sees sequence 12 after 10, it fetches the missing range before advancing its contiguous synchronization cursor. A missing sequence remains unresolved until the server confirms it is absent/filtered/deleted under the retention policy. Do not skip a gap because one immediate query returned no document.

### Pagination

- Older history: query `room_id` and `seq < before_seq`, sort descending, limit page size, reverse for display if required.
- Reconnect sync: query `seq > last_contiguous_seen_seq`.
- Deduplicate by message ID and sequence.
- PubSub arrival order is not authoritative; sort by `seq` and fetch gaps.

# 5. Message consistency and event flow

## 5.1 Send flow

```text
LiveView handle_event
       |
Validate content and size
       |
Authorize active membership
       |
Idempotency lookup
       |
Mongo transaction:
  increment counter + insert message
       |
Commit
       |
Broadcast new_message on room:<room_id>
       +----> room_activity on each recipient's user:<user_id>
       |
Sender UI: sending -> sent
```

A database failure returns an error and UI becomes `failed`. A PubSub failure after commit does not undo the message; reconnect synchronization recovers it.

## 5.2 Lost acknowledgement

If MongoDB commits but the acknowledgement is lost, the client retries with the same `client_message_id`. The unique index returns the existing message. Generate the ID when the composer is prepared, retain it across retries, and rotate it only after the server confirms persistence.

## 5.3 Oban cross-database limitation

MongoDB message persistence followed by a failed PostgreSQL Oban enqueue can lose a notification request. This is an accepted v1 limitation. Message persistence does not guarantee notification delivery. A durable outbox/reconciliation mechanism is required before promising reliable notifications.

# 6. Phoenix LiveView design

- Render messages with LiveView `stream/3`, not an ever-growing list assign. Load a bounded initial page and stream new messages and older-page inserts.
- Do not subscribe the sidebar to every room. Subscribe to `user:<user_id>` for lightweight room-activity/unread events. Subscribe to `room:<room_id>` only while an authorized room LiveView is open.
- A `phx-submit` while disconnected can be lost. V1 disables the composer while disconnected and preserves the draft where practical. Retain the same client ID for retries; rotate only after acknowledgement.
- A later JS hook may preserve pending sends across reconnects. Do not imply a normal disconnected LiveView form is durable.
- Acknowledgement is a LiveView state transition: `sending`, `sent`, or `failed`, driven by assigns. Delivery/read cursors are separate recipient state.

# 7. Authentication, authorization, and revocation

## 7.1 Authentication

Start from Phoenix's `phx.gen.auth` LiveView generator and customize it. This gives a reviewed baseline for password hashing, tokens, plugs, LiveView hooks, and session lifecycle.

- Argon2id (or the generated secure password-hashing configuration) is for passwords.
- High-entropy random session tokens are stored as SHA-256 hashes.
- Renew session on login.
- Store `user_agent`, `last_seen_at`, and expiry.
- Add tests for password reset, email confirmation, account enumeration, and session lifecycle as those features enter scope.
- Login/reset responses must not reveal whether an account exists.

## 7.2 Authorization

Authentication identifies the user; authorization decides whether that user may perform an operation. Every sensitive operation checks membership/permissions: opening history, subscribing, sending, editing/deleting, managing members, changing settings, and updating cursors.

## 7.3 Revoke active LiveViews

When a member is removed or leaves:

1. Commit the membership change in PostgreSQL.
2. Broadcast a revocation event to `user:<user_id>` and a membership event to `room:<room_id>`.
3. The affected LiveView unsubscribes, clears sensitive room state, and navigates away or shows access revoked.
4. Subsequent sensitive events re-check membership.
5. Any membership cache is short-lived and invalidated by membership events; PostgreSQL remains authoritative.

On logout/session revocation, broadcast disconnect on that session's `live_socket_id` topic (following Phoenix's generated auth pattern). Disconnect matching LiveView sockets and revalidate sessions on reconnect.

## 7.4 History visibility policy

V1 policy:

- A member can read messages created during that membership period: `created_at >= joined_at` and, if removed, `created_at < left_at`.
- New members cannot read messages from before `joined_at`.
- Former members cannot read messages created at or after `left_at`.
- Rejoining creates a new membership period and does not automatically restore access to messages from the previous period.
- Private-room participants follow the same rule.

Use UTC and server/database timestamps for boundary comparisons.

# 8. Presence and typing privacy

Do not expose a global online-users topic. Scope presence to users who share a room or an explicitly permitted contact relationship. Presence is ephemeral, may represent multiple sessions, and is not durable online-status data.

Use debounced PubSub typing broadcasts with a short TTL in v1. Broadcast only to authorized room members, expire stale indicators, and never persist typing events or include message contents.

# 9. Edits, deletion, and account deletion

## 9.1 Message edits

When implemented, only the sender (or explicitly authorized moderator) can edit. Update `edited_at`. V1 does not retain a full edit-history timeline; add a revision collection only if product requirements justify it.

## 9.2 Message deletion

A soft delete must purge the sensitive payload. Setting only `deleted_at` while retaining `content` is not deletion.

- Set `deleted_at`.
- Replace/purge `content` (e.g. `content: null` and a tombstone type).
- Preserve only minimal ordering/audit metadata allowed by retention policy.
- Broadcast `message_deleted`.
- Ensure history queries cannot return deleted content.

## 9.3 User deletion

Use a tombstone/anonymization policy:

- Replace public identity with “Deleted user”.
- Remove/anonymize email, username, avatar, and direct personal data according to policy.
- Preserve stable UUID references so message documents remain structurally valid.
- Do not automatically erase other users' conversation history unless policy requires it.
- Define separate message-content deletion and backup-expiry rules.

A tombstone alone does not establish legal GDPR compliance; jurisdiction-specific obligations require separate review.

# 10. Non-functional requirements — initial targets

These are project targets, not measured capacity claims. Validate with repeatable load tests.

| Requirement | Initial target |
|---|---|
| Concurrent authenticated users | 100 |
| Sustained message rate | 25 messages/second |
| Brief burst rate | 100 messages/second |
| Send-to-connected-recipient p95 | ≤ 500 ms in same-region test |
| Text message size | ≤ 4 KiB UTF-8 |
| Group size | ≤ 100 members |
| Initial history page | 50 messages |
| Retention | Indefinite during learning project unless deleted |
| Recovery | Reconnect sync recovers all authorized committed messages |
| Ordering | Monotonic per-room sequence |

Measure against a documented hardware/workload profile before treating these as service-level objectives.

# 11. Abuse controls and web security

- Rate-limit sends per user and IP using a shared store when multi-node deployment is introduced. Start with configurable burst and per-minute limits; tune from tests.
- Rate-limit login and password-reset attempts per IP and account identifier.
- Add blocking and enforce it in private-chat creation, sending, search, and notifications.
- User search must be paginated, rate-limited, and expose only necessary fields; do not expose an enumerable public directory.
- Configure Content-Security-Policy and appropriate security headers.
- HEEx escapes interpolated content by default. Never use `raw/1` for user-supplied message content.
- Validate/bound all input, including message size and metadata.
- Never log passwords, raw session tokens, message bodies, or database credentials.
- If link previews are added, defend against SSRF: block private/reserved IP ranges, revalidate redirects and DNS resolutions, and impose time/size limits.

# 12. Background jobs and reconciliation

Oban uses PostgreSQL for durable asynchronous work: email/push, expired-session cleanup, account maintenance, and reconciliation.

MongoDB has no foreign key to PostgreSQL rooms/users. Add an Oban reconciliation job that identifies messages whose `room_id` no longer exists. V1 room deletion is a tombstone followed by an explicit retention workflow. Reconciliation reports/quarantines unexpected orphan records; it must not silently delete them.

If Mongo message commit succeeds but Oban enqueue fails, the message remains while the notification may be lost. Log/measure this. Add an outbox/reconciliation mechanism before promising reliable notifications.

# 13. OTP and supervision

```text
ChatApp.Application
├── ChatAppWeb.Telemetry
├── ChatApp.Repo                 (PostgreSQL)
├── Mongo connection/pool        (MongoDB)
├── DNSCluster
├── Phoenix.PubSub
├── Presence
├── Oban
└── ChatAppWeb.Endpoint
```

Use OTP supervision for long-lived infrastructure and workers. Do not create one GenServer per user/room without a justified stateful ownership requirement.

Learning topics: BEAM processes, message passing, GenServer, supervisors, `:one_for_one`, `:one_for_all`, `:rest_for_one`, monitoring, PubSub, and distributed node communication.

# 14. Failure handling

| Failure | Expected behaviour |
|---|---|
| MongoDB unavailable before write | Fail send; UI `failed`; retry same client ID |
| PostgreSQL unavailable | Fail sensitive operation safely; do not trust stale membership indefinitely |
| Mongo commit succeeds but ack is lost | Retry same client ID; unique index returns existing message |
| PubSub broadcast fails after commit | Message remains; reconnect sync recovers it |
| PubSub arrives out of order | Sort by `seq`; fetch missing range |
| Sequence gap observed | Refetch; do not advance contiguous cursor until resolved |
| Member removed while connected | Revoke subscription, clear room data, navigate away; reject later events |
| Logout/session revoked | Disconnect session's LiveView sockets |
| Browser disconnects | Reauthenticate/re-authorize and sync from last contiguous sequence |
| Duplicate send | Unique idempotency index prevents duplicate |
| Orphaned message | Reconciliation reports/quarantines; apply retention policy |
| Room deleted while messages remain | Tombstone room; archive/purge according to policy |
| Oban enqueue fails after Mongo commit | Message remains; notification may be lost until outbox/reconciliation |
| Background job fails | Oban retry policy |
| Supervised process crashes | OTP supervisor restarts according to strategy |

Do not claim exactly-once network delivery. Aim for idempotent message creation, persistent history, ordered synchronization, and recoverable client state.

# 15. Testing strategy

Tests ship with the phase that introduces the behaviour.

## PostgreSQL

Use Ecto SQL Sandbox. Test uniqueness, private-room races, active-membership partial index, role constraints, session revocation, and monotonic cursor updates.

## MongoDB

MongoDB has no Ecto SQL Sandbox. Use a unique test database per test run, or a rigorously isolated cleanup strategy. Tests that share/truncate collections must be `async: false`. Never share dev collections with tests.

Test unique sequence/idempotency indexes, concurrent allocation, transaction abort/retry, duplicate retry, pagination, gap recovery, and deletion content purge.

## LiveView and browser

Test disconnected composer behaviour, stable client ID, `sending/sent/failed`, stream pagination, user-topic activity, room-topic authorization, removal while connected, logout disconnect, Alice/Bob chat, group visibility, and reconnect sync.

Every phase includes unit/integration tests for its behaviour and updates end-to-end coverage where relevant.

# 16. Tooling, versions, and CI

Pin Elixir and Erlang/OTP using mise or `.tool-versions`. Record Phoenix/LiveView versions in `mix.lock`; upgrade intentionally. The initial development environment used Elixir 1.20.5 / OTP 29.1.2 and Phoenix installer 1.8.17.

The project currently uses `mongodb_driver` 1.6.4. Its published docs list MongoDB 8 support, DBConnection pooling, sessions, transactions, and change streams. Verify the exact transaction API and test it against the project's replica set before relying on it.

Add CI early:

- `mix format --check-formatted`
- `mix test`
- Credo
- Dialyzer
- Sobelow
- `mix_audit`
- Asset build/compilation
- Integration job with PostgreSQL and MongoDB replica-set services

Pin tool versions and keep CI reproducible. Scanners complement, not replace, review and threat modelling.

# 17. Revised phase plan — vertical slices first

**Principle:** tests and acceptance criteria ship with every phase. Build a complete user workflow early.

## Phase 0 — Environment and engineering baseline

- Pin Elixir/OTP and dependency versions.
- Configure Docker databases and local secrets.
- Configure PostgreSQL.
- Configure MongoDB as a single-node replica set.
- Verify driver pooling/session/transaction behaviour.
- Add CI, formatter check, Credo, Dialyzer, Sobelow, `mix_audit`.
- Add health checks and safe configuration.

**Exit:** app boots; both DBs connect; replica set is healthy; CI runs; no secrets are committed.

## Milestone A — Alice and Bob private chat

### Phase 1 — Authentication and minimal accounts

- Start from `mix phx.gen.auth` LiveView generator.
- Customize registration/login/logout.
- Add session renewal, expiry, revocation.
- Add profile fields and case-insensitive uniqueness.
- Add authentication/account tests.

**Exit:** Alice and Bob register/login; session fixation and logout are tested; protected LiveViews reject anonymous users.

### Phase 2 — Minimal private room and authorization

- Create room and membership migrations.
- Implement canonical private pair (`user_low_id`, `user_high_id`).
- Add race-safe private-room creation.
- Add active-membership partial unique index.
- Implement membership-period visibility.
- Add authorization tests.

**Exit:** concurrent creation returns one canonical room; non-members cannot read or subscribe; constraints are tested.

### Phase 3 — Minimal LiveView chat screen

- Build room list and chat view.
- Use `stream/3` for messages.
- Subscribe to `user:<user_id>` for sidebar activity.
- Subscribe to `room:<room_id>` only after authorization.
- Disable composer while disconnected.
- Generate and retain `client_message_id` until acknowledgement.

**Exit:** users open authorized private rooms; message list is streamed/bounded; disconnected behaviour is tested.

### Phase 4 — Mongo persistence and ordering

- Create message/counter indexes.
- Implement transaction: increment counter + insert message.
- Add unique idempotency index.
- Implement duplicate retry lookup.
- Implement sequence-based pagination/sync.
- Add transaction/concurrency tests.

**Exit:** concurrent messages get unique sequences; retry does not duplicate; failed transaction cannot independently commit counter increment; history sorts by sequence.

### Phase 5 — Live delivery and reconnect recovery

- Broadcast only after Mongo commit.
- Broadcast `new_message` to room topic.
- Broadcast lightweight room activity to user topics.
- Implement `sending/sent/failed`.
- Implement sequence-gap fetch and reconnect sync.
- Test lost acknowledgement and out-of-order PubSub.

**Exit:** Alice sends/Bob receives; refresh retains history; lost-ack retry returns original; reconnect recovers committed messages without duplicates.

**Milestone A complete:** Alice and Bob can authenticate, open a private chat, send, receive, refresh, and recover history.

## Milestone B — Product functionality

### Phase 6 — Group rooms and membership lifecycle

- Group creation/management.
- Add/remove members and roles.
- Broadcast membership changes.
- Revoke active LiveViews.
- Enforce membership-period history visibility.

**Exit:** group members exchange messages; removed users stop receiving room events and cannot fetch later history.

### Phase 7 — Read/delivery cursors and unread counts

- Add `last_delivered_seq` and `last_read_seq`.
- Update cursors monotonically.
- Define delivery precisely.
- Compute unread counts.
- Publish sidebar/unread changes through user topic.

**Exit:** cursors never move backwards; offline users become delivered after sync; unread counts match eligible messages.

### Phase 8 — Presence, typing, and blocking

- Scope presence to shared rooms/contacts.
- Support multiple sessions.
- Add debounced typing with TTL.
- Add blocking and enforce across chat, search, and notifications.

**Exit:** no global online-user leak; typing expires; blocking prevents prohibited interactions.

## Milestone C — Reliability and hardening

### Phase 9 — Edits, deletion, and account lifecycle

- Message edit rules/timestamps.
- Message deletion purges content.
- Account tombstoning/anonymization.
- Room tombstones and orphan reconciliation.
- Retention/backup policy.

**Exit:** deleted content is not retrievable; user deletion preserves referential integrity; reconciliation detects orphans.

### Phase 10 — Security, performance, operations

- Rate limits per user/IP.
- CSP/security headers.
- Logs without secrets/message bodies.
- Load tests against NFR targets.
- Backup/restore drills.
- Metrics, health checks, production secrets, deployment.

**Exit:** NFRs measured; restore tested; security checks in CI; failure modes documented.

### Phase 11 — Distributed systems exploration

Multiple Phoenix nodes, distributed PubSub, clustering/load balancing, durable outbox/event recovery, change streams where justified, backpressure, multi-device sync, and OpenTelemetry.

This is intentionally separate from the first correct working application.

# 18. Key architectural decisions

| Decision | Reason |
|---|---|
| Modular monolith | Low operational complexity with clear contexts |
| LiveView for browser | No separate browser WebSocket client initially |
| PubSub for ephemeral delivery | Broadcast only after persistence |
| PostgreSQL for identity/rooms | Constraints, transactions, relational authorization |
| MongoDB for messages | Explicit learning objective |
| Mongo single-node replica set | Local transactions/change-stream compatibility |
| Per-room monotonic sequence | Safe ordering and reconnect sync |
| Transactional counter + insert | Avoid independent sequence allocation |
| Unique client idempotency index | Safe retries after lost acknowledgements |
| Membership-period history | Explicit new/former member visibility |
| Read/delivery cursors | Avoid receipt write amplification |
| LiveView streams | Avoid unbounded message assigns |
| Per-user PubSub topic | Efficient sidebar activity |
| Phoenix generated auth | Established session lifecycle foundation |
| Oban in PostgreSQL | Durable background jobs |
| Tests per phase | Catch regressions close to implementation |

# 19. Initial project milestone

1. Alice registers and logs in.
2. Bob registers and logs in.
3. Alice opens a private conversation with Bob.
4. The application creates/retrieves the canonical private room.
5. Both open authorized LiveViews.
6. Alice submits a message with a stable client-generated ID.
7. The server checks membership.
8. MongoDB allocates the room sequence and inserts the message in one transaction.
9. After commit, PubSub broadcasts the message.
10. Bob's LiveView streams it into the UI.
11. Alice's UI becomes `sent`.
12. Bob refreshes and retrieves the message by sequence.
13. A duplicate retry returns the existing message.

This validates authentication, both databases, authorization, transactions, LiveView, PubSub, idempotency, persistence, ordering, and synchronization.

# 20. Final engineering principle

Build a correct, persistent, authorized, and recoverable messaging workflow first. Do not optimize for massive scale before the basic invariants are tested.

The system does not promise exactly-once network delivery. It aims for:

- One persisted message per idempotency key.
- A monotonic sequence per room.
- Authorization at every sensitive boundary.
- Broadcast only after persistence.
- Reconciliation after missed events.
- Recoverable client state from persistent history.
