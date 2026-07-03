# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Docker deployment wrapper around Odamex (open-source multiplayer Doom engine).
There is no application source code here — the Dockerfile clones and compiles
`odasrv` (the Odamex dedicated server) from the upstream GitHub repo at build
time. This repo owns only the container packaging, runtime config, and
deployment (docker-compose).

Deployed on a homelab host `odroid` (192.168.1.201) for a deathmatch server,
with a longer-term goal of hosting a custom deathmatch conversion of Doom II
MAP24 ("The Chasm").

## Commands

```bash
docker compose build            # compiles odasrv from source (multi-stage build)
docker compose up -d            # start the server
docker compose logs -f          # tail server logs
docker compose down             # stop
```

There is no test suite, linter, or formatter in this repo — it's Dockerfile +
shell + Odamex `.cfg` files. "Testing" a change means rebuilding the image and
connecting a client:

```bash
odamex -connect 192.168.1.201:10666
```

Switch config without editing files:

```bash
ODAMEX_CONFIG=example.cfg docker compose up -d
```

Upgrade the Odamex version by bumping `ODAMEX_VERSION` in `.env` (build arg
`REPO_TAG`, default `12.2.1`), then `docker compose build`.

`.env` is gitignored and host-specific (`ODAMEX_VERSION`, `ODAMEX_UID`/
`ODAMEX_GID`, `ODAMEX_CONFIG`) — there's no `.env.example` in the repo, so
create it manually; see the README quick start for the variables it accepts.

## Architecture & non-obvious constraints

This is the important part — several of these were arrived at by debugging
real failures. Read before touching the Dockerfile, compose file, or configs.

### Build (Dockerfile, multi-stage)

- Stage 1 clones Odamex at a pinned tag (`ARG REPO_TAG`) and builds with
  `-D BUILD_CLIENT=0 -D BUILD_LAUNCHER=0`, which drops SDL2/SDL2_mixer/
  wxWidgets from the dependency graph entirely (they're `cmake_dependent_option`s
  scoped to those targets). Only zlib/zstd are real system deps; everything
  else (jsoncpp, cpptrace, miniupnp) comes in-tree via git submodules.
- **`python3` is REQUIRED in the build stage, not optional.** `odamex.wad` is
  generated at build time by `wad/odawad.py`. Without Python, CMake silently
  skips the wad ("Could NOT find Python, ODAMEX.WAD will not be built") and
  the runtime-stage `COPY` of `odamex.wad` fails.
- **The build must target `odasrv odawad`, not just `odasrv`.** The wad is
  produced by a separate `odawad` custom target; `odasrv` does NOT depend on
  it (the dependency runs the other way). Building only `--target odasrv`
  silently succeeds but produces no wad, and the runtime `COPY` then fails.
  Upstream's own Dockerfile has this same latent bug. The generated wad lands
  in `build/wad/odamex.wad` — the CMake step meant to also copy it into
  `server/` doesn't reliably fire, so the runtime stage `COPY`s straight from
  `wad/`.
- `patches/` is a hook for local patches (empty by default, same pattern used
  elsewhere for toolchain-compat fixes). Any `.patch` file dropped in there is
  applied with `patch -p1` before the submodule init/build.

### Runtime user — never root

- Container runs as UID/GID 1000 via the compose `user:` directive, mapping
  to the base image's built-in `ubuntu` user. No root phase, no runtime user
  creation, no gosu privilege-drop entrypoint (an earlier gosu-based design
  collided with Ubuntu 24.04+'s built-in `ubuntu` user already owning UID
  1000 — masked by an over-broad `|| true`, surfacing as a confusing gosu
  error). Running as `ubuntu` directly is simpler and strictly more secure.
- Assumes host UID 1000 (true across this homelab). If deploying where the
  host user isn't 1000, set `ODAMEX_UID`/`ODAMEX_GID` in `.env`.
- `ENV HOME=/home/ubuntu` is required in the Dockerfile — Docker does NOT
  populate `HOME` from `/etc/passwd` under the `user:` directive, and without
  it odasrv can't locate `~/.odamex`. Don't remove it.

### PID 1 / signals

- `tini` is the image `ENTRYPOINT`
  (`["tini", "--", "/usr/local/bin/odamex-server", "-host"]`), giving
  signal-forwarding/zombie-reaping regardless of how the image is launched.
  `-host` is fixed there; per-session args (wad, config, map) come from the
  compose `command:`.
- `odamex-server.sh` is a thin wrapper: `cd` into the install dir, `exec
  odasrv "$@"`.

### Networking

- Raw UDP 10666, no reverse proxy (consistent with other UDP game servers in
  this homelab — bypasses Caddy/TLS entirely).
- Router must forward **UDP 10666 → 192.168.1.201** for external access; not
  needed for LAN-only play.
- Bridge networking is the default; `network_mode: host` is the documented
  escape hatch if master-server registration or NAT ever becomes a problem
  (not currently used).

### Config loading and cvar timing

Which config loads is controlled by `ODAMEX_CONFIG` (compose interpolates
`configs/${ODAMEX_CONFIG:-config.cfg}`). **Note: only `configs/example.cfg`
currently exists in this repo** — `config.cfg` is the documented default but
is not present, so `ODAMEX_CONFIG` currently must be set explicitly (e.g. to
`example.cfg`) or the container will fail to find its config.

Cvars (`set <cvar> "<value>"`) fall into categories that determine WHERE a
setting must go — this has caused real bugs:

- **Run-loop / on-demand** (most `sv_*` gameplay cvars, e.g. `sv_fraglimit`,
  `sv_usemasters`): read after the `+exec`'d config applies. Put these in the
  `.cfg` file — the normal case.
- **Init-time** (`sv_upnp`): read during network init, BEFORE `+exec` runs. A
  `set` in the `.cfg` is too late — must be passed as `+set sv_upnp 0` on the
  command line (compose `command:`). Getting this wrong shows up as an ~8s
  UPnP discovery timeout at startup despite `sv_upnp "0"` in the config.
- **Server-authoritative** (`sv_freelook`, `sv_allowjump`): override the
  client's local setting entirely. If a client can't look up/down even with
  `cl_mouselook 1` set locally, fix `sv_freelook` on the server, not the
  client.
- **Latched** (e.g. `sv_gametype`): only take effect after a map change, not
  immediately.

Full cvar reference: https://odamex.net/wiki/Variables, or authoritative for
a given build: `cvarlist` in the server console, or
`server/src/sv_cvarlist.cpp` / `common/c_cvarlist.cpp` in Odamex source.

### Playtest loop for the MAP24 "Chasm" project

Custom PWADs are bind-mounted (`./wads:/wads:ro`), not baked into the image,
so iterating doesn't require a rebuild:

1. Copy the updated PWAD (e.g. `chasm_dm.wad`) into `./wads/` on the host.
2. Extend the compose `command:` to load it, e.g.:
   ```yaml
   command: >
     -iwad /wads/DOOM2.WAD
     -waddir /wads
     -file /wads/chasm_dm.wad
     +exec /configs/${ODAMEX_CONFIG:-config.cfg}
     +map MAP24
   ```
3. `docker compose up -d` to recreate with the new command — a plain
   `restart` won't pick up `command:` changes.
4. The client also needs a matching copy of the PWAD locally each iteration.

## What's gitignored (and why)

- `wads/*` — copyrighted IWAD/PWAD game data (keeps `wads/.gitkeep` so the dir
  exists after clone).
- `odahome/*` — runtime server state (keeps `odahome/.gitkeep`; tracking the
  empty dir means a fresh clone creates it owned by the cloning user, so
  Docker never auto-creates it as root, which would make it unwritable to the
  non-root container user).
- `.env` — host-specific values / potential secrets.
