# odamex-docker-server

Dockerized [Odamex](https://odamex.net/) dedicated server (`odasrv`), built from source. Compiles natively for whatever architecture it's built on — ARM64, x86-64, etc.

## Repo contents

```
.
├── Dockerfile            # multi-stage: compiles odasrv (server-only)
├── docker-compose.yml    # deployment: UDP 10666, bind mounts, .env-driven
├── entrypoint.sh         # tini + gosu privilege drop
├── odamex-server.sh      # launch wrapper
├── patches/              # optional .patch hook for toolchain fixes
├── configs/
│   └── config.cfg        # deathmatch-tuned server config
└── wads/                 # IWAD lives here (DOOM2.WAD is gitignored)
```

## Requirements

- Docker Engine + Compose plugin
- A legally-owned `DOOM2.WAD` (or another Doom/Doom II IWAD, or Freedoom)

## Setup

```bash
git clone <this-repo> odamex && cd odamex
cp .env.example .env          # then edit UID/GID to match your host
```

Drop your `DOOM2.WAD` into `wads/`. It's gitignored — it's copyrighted game data and never gets committed.

Set `ODAMEX_UID` / `ODAMEX_GID` in `.env` to your host user's `id -u` / `id -g` so the bind-mounted directories stay correctly owned.

## Run

```bash
docker compose build     # compiles odasrv from source (first build is slow)
docker compose up -d
docker compose logs -f
```

The pinned Odamex version is set by `ODAMEX_VERSION` in `.env`; bump it and rebuild to upgrade.

## Network

Raw UDP — no reverse proxy involved. Forward **UDP 10666** on your router to the host running this container. That's the only exposure needed.

## Config

Server behavior lives in `configs/config.cfg` (gametype, fraglimit, warmup, etc.). Change the `rcon_password` before exposing this publicly.

## Custom WADs

Drop a PWAD into `wads/` and extend the compose `command:`:

```yaml
command: >
  -iwad /wads/DOOM2.WAD
  -waddir /wads
  -file /wads/your_map.wad
  +exec /configs/config.cfg
  +map MAP01
```

Then `docker compose up -d` to recreate with the new args (a `restart` won't pick up command changes).