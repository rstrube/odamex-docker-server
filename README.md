# odamex-docker-server

A Dockerized [Odamex](https://odamex.net/) dedicated server (`odasrv`), built
from source in a multi-stage image. It compiles natively for whatever
architecture you build on (x86-64, ARM64, etc.) rather than shipping a
prebuilt binary, and runs as an unprivileged, non-root user by default.

---

## Features

- **Builds from source** — pins a specific Odamex release tag and compiles
  it in-container, so you get a native binary for your host architecture
  with no prebuilt-binary trust issues.
- **Server-only** — compiles just `odasrv`, skipping the client/launcher and
  their SDL2/wxWidgets dependencies entirely.
- **Runs unprivileged** — the container runs as a regular non-root user, not
  root with a privilege drop.
- **Proper signal handling** — uses `tini` as PID 1, so `docker stop` and
  friends work cleanly instead of leaving zombie processes or ignoring
  signals.
- **Config-driven** — server behavior lives in mountable `.cfg` files, no
  image rebuild needed to change gameplay settings.

---

## Quick start

```bash
git clone https://github.com/<you>/odamex-docker-server.git
cd odamex-docker-server
```

Place a legally-owned `DOOM2.WAD` (or another Doom/Doom II IWAD, or Freedoom)
in `./wads/` — it's gitignored, you supply your own.

Create a `.env` file to override defaults if needed (all optional):

```bash
ODAMEX_VERSION=12.2.1   # Odamex git tag to build
ODAMEX_UID=1000         # match your host user, for bind-mount permissions
ODAMEX_GID=1000
ODAMEX_CONFIG=example.cfg
```

Then build and run:

```bash
docker compose build     # compiles odasrv from source
docker compose up -d
docker compose logs -f
```

Connect with a client:

```bash
odamex -connect <host>:10666
```

---

## Repo layout

```
.
├── Dockerfile            # multi-stage: compiles odasrv + odamex.wad
├── docker-compose.yml    # deployment: UDP 10666, user directive, bind mounts
├── odamex-server.sh      # launch wrapper (cd to install dir, exec odasrv)
├── patches/              # optional .patch hook for toolchain fixes (empty)
├── configs/
│   └── example.cfg       # minimal MAP01 deathmatch config
├── wads/                 # IWAD lives here (gitignored; .gitkeep tracked)
└── odahome/              # runtime server state, mounted to ~/.odamex (.gitkeep tracked)
```

---

## Configuration (`configs/*.cfg`)

Which config loads is controlled by `ODAMEX_CONFIG` (defaults to
`example.cfg`):

```bash
ODAMEX_CONFIG=myconfig.cfg docker compose up -d
```

Server behavior is set via `set <cvar> "<value>"` lines. Full cvar
reference: https://odamex.net/wiki/Variables, or run `cvarlist` in the
server console for what's available in your build.

A few things worth knowing about cvar timing:

- Most `sv_*` gameplay cvars (fraglimit, maxplayers, etc.) just need to be
  in the `.cfg` file — they're read after it's `+exec`'d.
- A few cvars (e.g. `sv_upnp`) are read during network init, *before* the
  config loads. Those need to be passed as `+set sv_upnp 0` on the command
  line instead (see the `command:` block in `docker-compose.yml`).
- `sv_freelook` / `sv_allowjump` are server-authoritative — they override
  whatever the client has set locally.
- Some cvars (e.g. `sv_gametype`) are latched and only apply after a map
  change.

**Change `rcon_password` before exposing a server publicly.**

---

## Loading a custom PWAD

Additional wads (custom maps, mods) are bind-mounted from `./wads`, so
adding one doesn't require rebuilding the image — just extend the compose
`command:`:

```yaml
command: >
  -iwad /wads/DOOM2.WAD
  -waddir /wads
  -file /wads/mymap.wad
  +exec /configs/${ODAMEX_CONFIG:-example.cfg}
  +map MAP01
```

Run `docker compose up -d` (not `restart`) to pick up the new command, and
make sure clients have a matching copy of the PWAD.

---

## Building — things to know

- `python3` is required in the build stage: Odamex generates `odamex.wad`
  via a Python script at build time, and CMake silently skips it without
  Python present.
- The build targets `odasrv odawad` rather than just `odasrv`, since the wad
  is produced by a separate target that `odasrv` doesn't depend on.
- Drop `.patch` files into `patches/` if you need to patch the Odamex source
  before building (e.g. for toolchain compatibility); empty by default.
- Bump `ODAMEX_VERSION` in `.env` and rebuild to pick up a new Odamex
  release.

---

## Requirements

- Docker Engine + Compose plugin.
- A legally-owned `DOOM2.WAD` (or another Doom/Doom II IWAD, or Freedoom —
  adjust the `-iwad` path accordingly). Not committed; supply your own.

## What's gitignored

- `wads/*` (IWADs/PWADs — copyrighted game data), keeping `wads/.gitkeep`.
- `odahome/*` (runtime state), keeping `odahome/.gitkeep` so a fresh clone
  gets a directory owned by the cloning user rather than Docker creating it
  as root.
- `.env` (host-specific values / potential secrets).
