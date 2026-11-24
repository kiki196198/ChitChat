# Chatrooms — Development Setup Guide

This guide documents the local development setup for the Chatrooms application. It is intended for a developer setting up the project on a Linux machine for the first time.

## 1. Technology stack

- **Backend:** Elixir + Phoenix 1.8
- **Frontend:** Phoenix LiveView
- **Relational database:** PostgreSQL 17 (Docker)
- **Message database:** MongoDB 8.0 (Docker)
- **MongoDB client:** `mongodb_driver` 1.6.x
- **Background jobs:** Oban (planned; uses PostgreSQL)
- **Real-time broadcasting:** Phoenix PubSub

### Database responsibilities

| PostgreSQL | MongoDB |
|---|---|
| Users and authentication-related records | Chat messages |
| Rooms and memberships | Message-related receipts |
| Roles and permissions | Other message-focused documents |
| Oban jobs | |

PostgreSQL is the source of truth for application identity, room membership and permissions. MongoDB stores message data.

## 2. Prerequisites

Install the following tools before continuing:

- Git
- `mise` (used to manage language runtimes)
- Erlang/OTP and Elixir
- Node.js and npm
- Docker Engine
- Docker Compose plugin

The setup was completed on Pop!_OS 24.04 (Ubuntu Noble), x86_64. The versions used during setup were:

| Tool | Version |
|---|---:|
| Erlang/OTP | 29.1.2 |
| Elixir | 1.20.5 |
| Mix | 1.20.5 |
| Phoenix installer | 1.8.17 |
| Node.js | 24.22.3 |
| npm | 11.19.1 |
| Docker Engine | 29.10.0 |
| Docker Compose | 5.8.0 |

Other compatible versions may work; these are the versions used for the initial setup.

## 3. Project layout

The relevant project structure is:

```text
Chatrooms/
├── Markdowns/
│   └── initial_design_doc.md
├── docker/
│   ├── compose.yaml
│   └── .env                 # Local secrets; do not commit
└── chat_app/
    ├── config/
    │   └── dev.exs
    ├── lib/
    │   └── chat_app/
    │       └── application.ex
    ├── mix.exs
    └── ...
```

Run the following commands from the repository root unless a step says otherwise:

```bash
cd ~/work/Chatrooms
```

## 4. Start PostgreSQL and MongoDB with Docker

The Compose configuration defines two database services:

- PostgreSQL 17 Alpine, exposed on `127.0.0.1:5432`
- MongoDB 8.0, exposed on `127.0.0.1:27017`

Both services use named Docker volumes so their data survives container restarts.
MongoDB runs as an authenticated single-node replica set (`rs0`) so local
transactions are supported. Its member advertises `localhost:27017`, which is
reachable from the Phoenix process running on the host.

Create `docker/.env` with locally generated credentials. Use this shape, replacing every placeholder with a strong, unique value:

```dotenv
POSTGRES_USER=chat_app
POSTGRES_PASSWORD=<strong-postgres-password>
POSTGRES_DB=chatroom_dev

MONGO_INITDB_ROOT_USERNAME=chat_admin
MONGO_INITDB_ROOT_PASSWORD=<strong-mongodb-admin-password>
```

Restrict access to the file:

```bash
chmod 600 docker/.env
```

The repository `.gitignore` excludes `docker/.env` and `docker/.env.*`. Never commit this file or paste its secret values into chat, logs, documentation, or source control.

Generate the MongoDB internal-authentication keyfile once. It is separate from
the MongoDB administrator and application passwords:

```bash
umask 077
openssl rand -base64 756 > docker/mongo-keyfile
chmod 600 docker/mongo-keyfile
```

The keyfile is ignored by Git. Keep it available across container restarts; all
members of a replica set must share the same key.

Validate and start the database containers:

```bash
docker compose -f docker/compose.yaml config --quiet
docker compose -f docker/compose.yaml up -d
docker compose -f docker/compose.yaml ps
```

Wait until both containers report healthy. On its first start, MongoDB's
healthcheck initializes `rs0` and remains unhealthy until the node is primary.
The named database volume is preserved when the container is recreated, so do
not remove it as a routine troubleshooting step.

### Create a dedicated MongoDB application user

Do not connect the Phoenix application as the MongoDB root administrator.

Connect to the MongoDB container using the root credentials from `docker/.env`, then switch to the application database and create a restricted user:

```javascript
use chatroom_messages

db.createUser({
  user: "chat_app",
  pwd: passwordPrompt(),
  roles: [{ role: "readWrite", db: "chatroom_messages" }]
})
```

Enter a strong password when prompted and store it securely. The application authenticates against `chatroom_messages` using this user. The root account is only for database administration.

> If the application user already exists, do not create it again. Verify that it has the `readWrite` role on `chatroom_messages`.

## 5. Generate and install the Phoenix application

If the Phoenix project has not already been generated, install the Phoenix installer and generate a LiveView application:

```bash
mix archive.install hex phx_new
mix phx.new chat_app --live
```

Follow the prompts and allow Mix to install dependencies.

Enter the application directory:

```bash
cd chat_app
```

Fetch and compile dependencies:

```bash
mix deps.get
mix deps.compile
```

The application in this repository has already been generated; do not run `mix phx.new` again over an existing project.

## 6. Configure PostgreSQL

The Phoenix project uses Ecto through `ChatApp.Repo`.

In `chat_app/config/dev.exs`, configure the repository using environment variables rather than hardcoded credentials:

```elixir
config :chat_app, ChatApp.Repo,
  username: System.fetch_env!("POSTGRES_USER"),
  password: System.fetch_env!("POSTGRES_PASSWORD"),
  hostname: "127.0.0.1",
  database: System.fetch_env!("POSTGRES_DB"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
```

The `127.0.0.1` hostname matches the loopback-bound Docker port mapping.

Load the variables from the repository's Docker environment file in the same terminal session:

```bash
cd ~/work/Chatrooms/chat_app

set -a
source ../docker/.env
set +a
```

Create the development database:

```bash
mix ecto.create
```

Ecto migrations will be used to create and evolve PostgreSQL tables as application features are implemented.

## 7. Configure MongoDB

The application uses the Hex dependency `mongodb_driver`:

```elixir
{:mongodb_driver, "~> 1.6"}
```

After adding it to the dependency list in `chat_app/mix.exs`, fetch and compile it:

```bash
mix deps.get
mix deps.compile
```

Add the MongoDB configuration to `chat_app/config/dev.exs`:

```elixir
config :chat_app, ChatApp.Mongo,
  name: ChatApp.Mongo,
  url: "mongodb://127.0.0.1:27017/chatroom_messages",
  username: "chat_app",
  password: System.fetch_env!("MONGO_APP_PASSWORD"),
  auth_source: "chatroom_messages",
  pool_size: 5
```

Add the application user's password to `docker/.env` (do not use the root password):

```dotenv
MONGO_APP_PASSWORD=<password-for-the-chat_app-mongodb-user>
```

A password can be entered without echoing it in the terminal and appended to the environment file with:

```bash
read -rsp "MongoDB application password: " MONGO_APP_PASSWORD
printf '\n'
printf 'MONGO_APP_PASSWORD=%s\n' "$MONGO_APP_PASSWORD" >> ../docker/.env
unset MONGO_APP_PASSWORD
```

Only run that append command if `MONGO_APP_PASSWORD` is not already present in the file; otherwise it could create duplicate entries.

Reload the variables whenever a new terminal session is used:

```bash
set -a
source ../docker/.env
set +a
```

## 8. Add MongoDB to the OTP supervision tree

In `chat_app/lib/chat_app/application.ex`, add the MongoDB connection as a child of the existing application supervisor.

The relevant part of the `children` list should look like this:

```elixir
children = [
  ChatAppWeb.Telemetry,
  ChatApp.Repo,
  {Mongo, Application.fetch_env!(:chat_app, ChatApp.Mongo)},
  {DNSCluster, query: Application.get_env(:chat_app, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: ChatApp.PubSub},
  ChatAppWeb.Endpoint
]
```

Keep the other generated children and the existing `:one_for_one` supervision strategy.

This starts the MongoDB connection pool as part of the Phoenix application lifecycle. The connection is registered as `ChatApp.Mongo`, which is the name used by MongoDB operations.

## 9. Start the application

### Configure Firebase Google sign-in

The current authentication flow uses Firebase Authentication for Google sign-in.
In the Firebase project, enable **Google** under Authentication → Sign-in
providers and set a support email. Add `localhost` under Authentication →
Settings → Authorized domains for local development. The web app's public
configuration is bundled in `chat_app/assets/js/app.js`; it is safe to expose
in browser code. The server verifies Firebase ID tokens against the configured
project ID before creating a Chatrooms session. Do not accept an email or UID
posted by the browser without verifying the signed token.

The web app config supplied for this implementation uses project ID
`chatrooms-63eac`. Use that project in the Firebase console. Analytics is not
initialized because it is not part of the sign-in flow.

Ensure the database containers are running:

```bash
docker compose -f ../docker/compose.yaml ps
```

From the repository root, start the databases. On a fresh checkout, the Compose
file and the local credentials/keyfile described above must already be set up:

```bash
docker compose -f docker/compose.yaml up -d
docker compose -f docker/compose.yaml ps
```

Then open a terminal in `chat_app`, load the ignored credentials, and prepare
the application. `mix setup` fetches dependencies, creates/migrates the
development database, runs seeds, and builds assets. Run it on first setup or
after dependency/schema changes:

```bash
cd ~/work/Chatrooms/chat_app
set -a
source ../docker/.env
set +a

mix setup
mix phx.server
```

Open:

```text
http://localhost:4000
```

The Chatrooms landing page should load. Continue with Google to create or access
your account. On first sign-in, Chatrooms creates a profile using the verified
Google email, name, and photo; you can edit the display name, username, and
avatar in Account settings. Open `/rooms` and enter another user's exact
username to start a private conversation, or create a group from the same page
and invite users by exact username. Group owners manage admins and membership;
admins can invite and remove regular members. Messages are persisted in MongoDB,
ordered per room, and loaded from history when you reopen a conversation. An
open room syncs missed messages after reconnect and fills sequence gaps when
live events arrive out of order.

For later starts, start Docker if needed, load `docker/.env` in the `chat_app`
terminal, and run `mix phx.server`.

## 10. Run tests

The test alias creates and migrates a separate PostgreSQL database named
`<POSTGRES_DB>_test`, then runs ExUnit. Load the same local environment first:

```bash
cd ~/work/Chatrooms/chat_app
set -a
source ../docker/.env
set +a
mix test
```

Run one test file while iterating:

```bash
mix test test/chat_app/rooms_test.exs test/chat_app_web/room_live_test.exs
```

The application currently points test MongoDB connections at the local
`chatroom_messages` database. Add a separate test database before adding
Mongo-backed tests. Auth tests should validate Firebase token verification and
the server-created session without relying on a live Google sign-in popup.

### Verify MongoDB from the running application

Stop the server with `Ctrl+C`, then run this from `chat_app` with the environment variables loaded:

```bash
mix run -e 'IO.inspect(Mongo.ping(ChatApp.Mongo))'
```

A successful ping returns a result similar to:

```elixir
{:ok, %{"ok" => 1.0}}
```

A write/read smoke test can also be run:

```bash
mix run -e '
check_id = Ecto.UUID.generate()

IO.inspect(
  Mongo.insert_one(ChatApp.Mongo, "connection_checks", %{
    check_id: check_id,
    purpose: "connection_test"
  }),
  label: "INSERT"
)

IO.inspect(
  Mongo.find(ChatApp.Mongo, "connection_checks", %{check_id: check_id})
  |> Enum.to_list(),
  label: "READ"
)
'
```

This inserts a temporary test document and reads it back. The `connection_checks` collection is only for this setup smoke test; it is not the application's message collection.

## 11. Common setup notes

### Current room behavior (Phases 7–8)

- Room member rows store monotonic delivered/read sequence cursors. Delivery is
  recorded after a connected member's LiveView fetches persisted history or a
  new message batch; read state follows the latest rendered message reported
  by the browser.
- The `/rooms` list shows unread counts. Counts exclude the current user's
  messages and messages outside the current membership period.
- Presence is scoped to each authorized room. A user stays online while any of
  their room sessions are connected. Typing indicators are room-only and
  expire after 3.5 seconds without an update.
- Blocking is available from a private room. It prevents new private room
  creation, username lookup, sending, unread counts, and activity fanout for
  that pair. PostgreSQL migrations are applied with `mix ecto.migrate`.

- **Environment variables are per terminal session.** Run the `set -a; source ../docker/.env; set +a` commands again in every new terminal before running Mix tasks that need database credentials.
- **Do not commit secrets.** Keep `docker/.env` local and use a separate secret-management approach for shared or production environments.
- **Do not use the MongoDB root account in Phoenix.** Use the restricted `chat_app` user.
- **Start databases before Phoenix.** Check container health with `docker compose ... ps`.
- **Compiler warnings are not always failures.** During this setup, dependencies emitted compiler warnings, but compilation completed and generated the application. Investigate warnings if compilation fails or behavior is incorrect.
- **Development configuration is not production configuration.** Production secrets, database URLs, TLS, network exposure and deployment settings must be configured separately.

## Setup completion checklist

- [ ] Docker PostgreSQL is healthy and MongoDB reports a writable `rs0` primary.
- [ ] `docker/mongo-keyfile` exists locally and is not committed.
- [ ] PostgreSQL development database was created with `mix ecto.create`.
- [ ] MongoDB application user has `readWrite` access to `chatroom_messages`.
- [ ] `mongodb_driver` dependency is installed and compiled.
- [ ] Phoenix starts with MongoDB in its OTP supervision tree.
- [ ] Firebase Authentication has Google enabled and `localhost` authorized.
- [ ] The sign-in page loads at `http://localhost:4000/users/log-in`.
- [ ] Google sign-in creates a local Chatrooms profile and session.
- [ ] MongoDB ping succeeds.
- [ ] MongoDB insert/read smoke test succeeds.
