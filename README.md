# Chatrooms

Chatrooms is a real-time messaging application built with Elixir, Phoenix LiveView, PostgreSQL, and MongoDB. It supports private conversations and group rooms, with a focus on reliable message ordering, membership authorization, and reconnect recovery.

**Deployment:** Hosted on Render using the Docker image in [`chat_app/Dockerfile`](chat_app/Dockerfile).

## What works today

- Google sign-in through Firebase Authentication. The Phoenix server verifies Firebase ID tokens before establishing a Chatrooms session.
- User profiles with editable display names, usernames, and avatars.
- Private conversations found by exact username, plus group rooms with invitations and owner/admin/member roles.
- Persistent text messages, ordered per room and stored in MongoDB. Retries are idempotent, and message history is restored when a room is reopened.
- Live message delivery with reconnect and sequence-gap recovery.
- Room-scoped presence and typing indicators.
- Delivery/read cursors and unread counts.
- Private-user blocking, including preventing new private conversations and message activity between blocked users.
- Membership-period history and permission checks, including access revocation when a member is removed.

## Project status

The core chat experience is implemented, including the room and messaging work tracked as Phases 3–8 in the implementation notes. The project is still under active development; a Render deployment does not mean every planned feature or production-hardening task is complete.

### In progress / next

- Complete Firebase token and session tests, and replace outdated generated email/password and magic-link authentication tests.
- Finish the engineering baseline: CI, security/static-analysis checks, and broader MongoDB transaction and test-isolation coverage.
- Implement Phase 9: message edits and deletion, plus account and room lifecycle behavior.
- Continue production hardening, including operational monitoring, backup/restore procedures, and abuse controls.

### Not implemented / later scope

File uploads, reactions, search, push notifications, end-to-end encryption, advanced moderation, and multi-device support are not part of the current feature set. Oban-backed background jobs and distributed/multi-node deployment are also future work.

For the detailed phase-by-phase record and development caveats, see [`Markdowns/implementation_notes.md`](Markdowns/implementation_notes.md). The broader architecture and roadmap are in [`Markdowns/initial_design_doc_v3.md`](Markdowns/initial_design_doc_v3.md).

## Technology

| Area | Technology |
|---|---|
| Application | Elixir, Phoenix 1.8, Phoenix LiveView |
| Relational data | PostgreSQL with Ecto |
| Messages | MongoDB with `mongodb_driver` |
| Real-time updates | Phoenix PubSub and Presence |
| Authentication | Firebase Authentication (Google sign-in) |
| Assets | Tailwind CSS and esbuild |
| Local databases | Docker Compose |
| Hosting | Render, using the project's Dockerfile |

PostgreSQL is the source of truth for users, sessions, rooms, memberships, and permissions. MongoDB stores message documents and per-room sequence counters.

## Run locally

### Prerequisites

Install Elixir/Erlang, Node.js/npm, Docker, and Docker Compose. Local development uses PostgreSQL and a MongoDB single-node replica set in Docker. See [`Markdowns/dev_setup.md`](Markdowns/dev_setup.md) for the full setup, including local credentials, Firebase configuration, and database initialization.

### Start the app

From the repository root, first complete the one-time setup in the development guide (including `docker/.env`, the MongoDB keyfile, and the MongoDB application user), then run:

```bash
docker compose -f docker/compose.yaml up -d

cd chat_app
set -a
source ../docker/.env
set +a

mix setup
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000). To use Google sign-in locally, enable Google as a Firebase Authentication provider and authorize `localhost` in the Firebase console.

Run the test suite from `chat_app` after loading the same local environment:

```bash
mix test
```

**Test status:** Room and messaging behavior has focused test coverage. The complete suite still needs authentication-test updates; some generated tests exercise the old email/password and magic-link flow.

## Render deployment

The Dockerfile builds a Phoenix release, runs Ecto migrations at container startup, and starts the web server. Configure the production environment with:

- `DATABASE_URL` — PostgreSQL connection URL.
- `MONGO_URL` — MongoDB connection URL; production MongoDB connections use TLS.
- `SECRET_KEY_BASE` — generate with `mix phx.gen.secret`; keep it in Render's environment settings, not in source control.
- `PORT` — supplied by Render; the app listens on this port.
- `RENDER_EXTERNAL_HOSTNAME` — supplied by Render and used to construct the canonical HTTPS host.

The Firebase project is currently configured as `chatrooms-63eac`. Ensure the deployed hostname is authorized in Firebase Authentication. Use managed production databases and set their URLs and credentials as Render secrets/environment variables; do not reuse local Docker credentials.

## Repository layout

```text
Markdowns/       Development guide, implementation notes, and design docs
chat_app/        Phoenix application, assets, migrations, tests, and Dockerfile
docker/          Local PostgreSQL and MongoDB Compose configuration
```

## Disclaimer

This is a vibe-coded project. Please don't exploit any vulnerabilities. Also, don't trust the READMEs — I didn't write them. Let me live in blissful ignorance. 🥲