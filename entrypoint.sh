#!/usr/bin/env bash
set -exu

# Container must start as root so it can create the mapped user below;
# gosu then drops to that user before odasrv actually runs.
if (( "$(id -u)" != 0 )); then
    echo "This entrypoint must run as root (it drops privileges itself)."
    echo "Set ODAMEX_UID / ODAMEX_GID instead of changing the container user."
    exit 1
fi

[[ -n "${ODAMEX_GID-}" ]] && GID_OPTION="--gid ${ODAMEX_GID}"
groupadd odamex --force ${GID_OPTION-}

[[ -n "${ODAMEX_UID-}" ]] && UID_OPTION="--uid ${ODAMEX_UID}"
useradd doomguy --create-home ${UID_OPTION-} \
    --shell /sbin/nologin \
    --group odamex \
    || true  # don't fail if the user already exists from a prior run

exec gosu doomguy:odamex odamex-server -host "$@"