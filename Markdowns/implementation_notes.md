# Implementation notes

Short handoff notes for work that follows the design plan in
[`initial_design_doc_v3.md`](initial_design_doc_v3.md).

## Phase 0 — Environment and engineering baseline (in progress)

- Added `chat_app/.tool-versions` to pin Erlang/OTP 29.1.2, Elixir 1.20.5
  (OTP 29), and Node.js 24.22.3, matching the versions recorded in
  `dev_setup.md`.
- PostgreSQL and MongoDB are configured in Docker Compose with local-only port
  bindings and container health checks. Development credentials come from the
  ignored `docker/.env` file.
- MongoDB Compose configuration now enables authenticated single-node replica
  set `rs0`, uses an ignored local keyfile, initializes the replica set in its
  healthcheck, and waits for a writable primary. Phoenix's development URI opts
  into `rs0`.
- `docker compose ... config --quiet` passes. The MongoDB container was
  recreated with its named data volume kept, and its healthcheck reports healthy
  only after `rs0` is a writable primary.
- `mix format` and `mix compile --warnings-as-errors` pass on the pinned toolchain.
- The checked-in `mongodb_driver` 1.6 docs expose `Mongo.transaction/3` with
  retries for transient transaction and uncertain commit errors. Phase 4 now
  exercises sequence allocation and message insertion through that API against
  the local replica set, including a forced-abort rollback check.
- CI, security/static analysis jobs, and explicit Mongo driver session and
  broader transaction error/retry verification remain outstanding. Phase 0
  remains in progress until its CI/scanner work is complete.

## Phase 1 — Authentication and minimal accounts (implementation in progress)

- Replaced the generated email/password and email-confirmation flow with
  Firebase Google sign-in. Browser SDK obtains the Firebase ID token; Phoenix
  verifies its RS256 signature, issuer, audience, expiry, verified email, and
  Google provider claim before creating a local session.
- Users have case-insensitive email and username fields, a required display
  name, optional avatar URL, Firebase UID, and tombstone timestamp. First
  sign-in creates a generated username and profile from Google claims. Users
  can update the profile in Account settings. Automatic linking by email is
  rejected; account linking needs an explicit product flow.
- Added a dedicated PostgreSQL `sessions` table. Cookies hold high-entropy raw
  tokens; only SHA-256 hashes are stored. Sessions retain bounded user-agent,
  authenticated/last-seen times, and a 14-day expiry. Logout and account-wide
  revocation disconnect LiveViews by session ID. Login renews the Plug session;
  production cookies use the Secure flag.
- Added a consistent minimal dark theme and branded landing/auth/account
  screens. The home preview and Firebase sign-in page were visually inspected.
- Added Firebase web SDK to the asset bundle. The config object is public and
  uses project ID `chatrooms-63eac`; Analytics is not loaded. Enable Google in
  Firebase Authentication and authorize `localhost` before local sign-in.
- Added a migration for Firebase UID and removal of the old password hashes,
  confirmation timestamp, and email token table. The local dev database was
  reset with the user's approval and all migrations were applied.
- `mix format`, `mix compile --warnings-as-errors`, and `mix assets.build` pass
  after the Firebase switch. Auth tests still need to be rewritten for mocked
  Firebase tokens; the older generated password/magic-link tests no longer
  describe the app. Run instructions are in `dev_setup.md`.

## Phase 2 — Minimal private rooms and authorization (in progress)

- Added PostgreSQL `rooms` and `room_members` schemas with UUID keys, private
  pair identity, creator, role, membership periods, and reserved group-room
  shape. Database constraints enforce valid room shape, ordered private pairs,
  allowed roles, nonnegative/ordered cursors, and valid membership periods.
- A partial unique index guarantees one active membership per `(room_id,
  user_id)` while retaining prior membership periods. A unique private-pair
  index plus `INSERT ... ON CONFLICT DO NOTHING` makes concurrent private-room
  creation converge on one canonical room. New rooms and their two memberships
  are inserted atomically.
- Added scoped APIs to create/get a private room, check active membership, and
  evaluate message visibility against a user's historical membership periods.
  Room lookups hide nonexistent and unauthorized rooms. Phase 3 must authorize
  before subscribing a LiveView to a room topic.
- Focused Phase 2 tests pass: canonical pair and two memberships, concurrent
  create convergence, nonmember denial, membership-period visibility, self-chat
  rejection, and the active-membership database constraint.
- The focused test command still emits compile warnings from old generated
  password/magic-link test fixtures; those fixtures need replacement as part
  of Phase 1 test cleanup. No room-domain test failures remain.

## Phase 3 — Minimal LiveView chat screen (complete)

- Added authenticated `/rooms` and `/rooms/:id` LiveViews inside the existing
  `:require_authenticated_user` live session. The room list searches by exact
  username, opens/returns the canonical private room, and subscribes only to
  the signed-in user's `user:<id>` topic for room activity.
- The chat view verifies active membership before subscribing to
  `room:<id>`, and checks membership again before sending or rendering an
  incoming message. Messages use a bounded LiveView stream (100 items).
- Added authenticated live PubSub message exchange with a bounded stream and
  disconnected composer behavior. Phase 4 now supplies persistence and order.
- The composer disables while disconnected. Its hook preserves the draft and
  client message ID in tab-scoped storage across reconnects, retains the ID
  through retries, and rotates it after the server acknowledges the send.
- Sign-in now lands in `/rooms`; the landing page and authenticated navigation
  lead into the room workspace. The room list updates from user-topic activity.
- Focused Phase 2/3 tests pass: 10 total for room constraints, race-safe
  creation, authorization, membership-period visibility, room navigation,
  live delivery, and disconnected composer rendering. Older generated auth
  test cases still expect the removed email/password and magic-link APIs and
  need replacement before the full legacy suite can run cleanly.

## Phase 4 — Mongo persistence and ordering (complete)

- Added unique Mongo indexes for `(room_id, seq)` and
  `(room_id, sender_id, client_message_id)`. The OTP startup index worker creates
  them idempotently before the endpoint starts.
- Added `ChatApp.Messaging`: it rechecks active PostgreSQL membership, looks up
  the idempotency key, then increments the room counter and inserts the message
  in one Mongo session transaction. A retry returns the stored message; if a
  write reports failure after an uncertain commit, the idempotency lookup
  recovers the committed document before returning an error.
- Persisted text documents include UUID identifiers, sender, client key,
  sequence, body/content, creation/edit/deletion timestamps. Initial history is
  bounded to 100 and selected by the active membership period, sorted by
  sequence. `list_messages_before/4` and `list_messages_after/4` expose bounded
  sequence pagination and gap-sync queries. LiveView keeps its bounded stream
  ordered by that sequence.
- LiveView broadcasts only after the Mongo transaction returns committed, and
  rotates the client message ID only after persistence succeeds. The room UI
  now describes messages as saved.
- Focused Phase 4 suite passes: seven room LiveView/integration tests covering
  concurrent sequence allocation, duplicate retry, persisted history and
  sequence pagination, live delivery, authorization, disconnected rendering,
  and a forced transaction abort that confirms the counter update rolls back.
  Phase 5 adds reconnect recovery using those sequence queries.

## Phase 5 — Live delivery and reconnect recovery (complete)

- The authorized room LiveView subscribes before loading its bounded history,
  closing the load/subscribe race. It tracks the highest contiguous sequence
  represented in its cache.
- The composer hook requests a server sync after reconnect. The LiveView fetches
  messages after its contiguous sequence in bounded batches, rechecks active
  membership, and deduplicates by sequence while keeping the 100-message stream
  ordered. Large backlogs continue in additional bounded batches.
- A PubSub event that skips a sequence triggers a persisted fetch to fill the
  gap. Out-of-order and duplicate room events therefore converge on Mongo's
  committed sequence order. Room activity is emitted only after persistence;
  reconnect sync recovers a missed activity/message broadcast.
- The composer keeps its client ID and draft in session storage until the
  server's post-commit acknowledgement. Retrying after a lost acknowledgement
  returns the stored message and does not create a duplicate. Persistence
  failures keep the ID for retry; successful sends clear the draft and rotate
  the ID.
- Focused Phase 5 tests cover missed-message reconnect sync, out-of-order and
  duplicate PubSub, lost-ack retry, live delivery and composer behavior.

## Phase 6 — Group rooms and membership lifecycle (complete)

- Added group room creation from `/rooms`, mixed private/group room listings,
  and a group member panel with username invitations and role/member controls.
  Group size is capped at 100 active members.
- Group creators are owners. Owners can assign admins/members, transfer
  ownership, remove members, and leave after transferring ownership. Admins can
  invite users and remove regular members. Membership-changing operations lock
  the room row and recheck current roles to serialize concurrent management.
- Adds create a new membership row; remove/leave close the current period. A
  rejoin begins strictly after the prior `left_at`. History queries filter from
  `joined_at`, preventing a rejoined member from seeing prior-period messages.
- Room-topic membership events refresh active member lists and immediately
  revoke removed users' open views. User-topic revocation refreshes their room
  index. Sensitive message/member assigns are cleared before redirecting.
- Room activity fanout now targets every active member, including groups.
- Focused private/group room suites pass: 19 tests covering group creation and
  listing, owner/admin permissions and transfer, rejoin history isolation,
  group chat, and immediate active-view revocation, alongside Phase 4/5 cases.

## Phase 7 — Delivery/read cursors and unread counts (complete)

- Room membership rows use `last_delivered_seq` and `last_read_seq`. Delivery
  advances only after an active recipient's LiveView fetches persisted messages
  from Mongo during initial load, reconnect, or gap recovery. Batches are
  bounded at 100 and continue asynchronously. Read advances when the client
  reports the latest rendered message sequence; the server accepts it only
  through that LiveView's highest contiguous sequence.
- Cursor writes are monotonic (`GREATEST`), scoped to active room membership,
  and reject sequences beyond Mongo's latest room sequence. Read advancement
  also advances delivery. Changes broadcast a user-topic cursor event.
- Unread counts include non-self, non-deleted messages from the current
  membership period above the read cursor. The room index refreshes counts on
  message activity/cursor updates and shows a compact badge. Private-room
  unread counts are suppressed while either user blocks the other.
- Focused room suites pass (23 tests total), including monotonic cursor
  updates, unread count changes, and future-sequence rejection.

## Phase 8 — Presence, typing, and blocking (complete)

- Added room-scoped Phoenix Presence topics (`room-presence:<room-id>`). Each
  LiveView session tracks separately, so online state remains while any
  session for that user is connected. Presence is limited to authorized room
  members; blocked private-chat peers are untracked. The room header and group
  member list show online status.
- The composer emits debounced typing state. The server throttles repeat
  broadcasts, publishes only to the room topic, and expires stale indicators
  after 3.5 seconds. A stop event, blur, submit, or block clears typing state.
- Added directed block records with duplicate/self-block protection. Blocking
  prevents private-room creation and lookup, message sending, unread counts,
  and private-room activity fanout. Group room interactions are unaffected.
  Both users receive relationship-change events so open views update the
  composer, presence and typing state immediately.
- Added private-room block/unblock controls and blocked-state messaging.
- `mix format`, `mix compile --warnings-as-errors`, `mix assets.build`, and the
  focused room suites pass: 23 tests covering cursor, block, presence, typing,
  read-receipt and room lifecycle behavior.

### Next work

Complete Firebase token/session tests and replace obsolete generated auth test
fixtures. Phase 9 covers edits, deletion, and account/room lifecycle. Keep the
visual direction minimal, sharp, and dark with restrained warm-metal accents.
