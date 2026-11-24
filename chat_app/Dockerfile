FROM hexpm/elixir:1.17.3-erlang-27.2.4-debian-bookworm-20261123-slim AS build

RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git nodejs npm && rm -rf /var/lib/apt/lists/*
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mkdir -p priv
COPY priv priv
COPY lib lib
COPY assets assets
RUN npm ci --prefix assets
RUN mix deps.compile
RUN mix compile
RUN mix assets.deploy
RUN mix release

FROM hexpm/elixir:1.17.3-erlang-27.2.4-debian-bookworm-20261123-slim AS app
RUN apt-get update -y && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
COPY --from=build /app/_build/prod/rel/chat_app ./
EXPOSE 10000
CMD ["/bin/sh", "-c", "/app/bin/chat_app eval 'ChatApp.Release.migrate' && exec /app/bin/chat_app start"]
