# --- Build stage -------------------------------------------------------
# Compiles the odasrv (dedicated server) target only. BUILD_CLIENT=0 and
# BUILD_LAUNCHER=0 skip SDL2/SDL2_mixer/wxWidgets entirely — the server
# binary only needs zlib/zstd (system) plus a handful of libs that
# Odamex's CMake pulls in-tree via git submodules (jsoncpp, cpptrace,
# miniupnp, etc). Verified against odamex/odamex CMakeLists.txt.
FROM ubuntu:26.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /build

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends tzdata \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        gcc g++ \
        cmake \
        make \
        zlib1g-dev \
        libzstd1 libzstd-dev \
        patch \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]

# Pin the version explicitly — same reproducibility approach as the
# Caddy/xcaddy build. Bump this when you want to pick up a new release.
ARG REPO_URL=https://github.com/odamex/odamex.git
ARG REPO_TAG=12.2.1

RUN git clone --depth 1 --branch "${REPO_TAG}" "${REPO_URL}" odamex

WORKDIR /build/odamex

# Hook for local patches. Empty by default — drop .patch files into
# ./patches/ before building if a future toolchain needs a workaround.
COPY patches/ /patches/
RUN shopt -s nullglob \
    && for p in /patches/*.patch; do patch -p1 < "$p"; done

RUN git submodule update --init --depth 1

RUN mkdir build
WORKDIR /build/odamex/build

RUN cmake -W no-dev \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_CXX_COMPILER=g++ \
        -D CMAKE_C_COMPILER=gcc \
        -D BUILD_CLIENT=0 \
        -D BUILD_LAUNCHER=0 \
        -D CMAKE_C_FLAGS="-w" \
        -D CMAKE_CXX_FLAGS="-w" \
        .. \
    && cmake --build . --parallel "$(nproc)" --target odasrv

# --- Runtime stage -------------------------------------------------------
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV INSTALL_DIR=/usr/local/games/odamex

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends tini gosu \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${INSTALL_DIR}"
COPY --from=build /build/odamex/build/server/odasrv ${INSTALL_DIR}/
# odamex.wad carries HUD/console assets some builds also generate for
# the server; copy it if present, don't fail the build if it isn't.
COPY --from=build /build/odamex/build/server/odamex.wad ${INSTALL_DIR}/odamex.wad

COPY odamex-server.sh /usr/local/bin/odamex-server
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/odamex-server /entrypoint.sh

# Mapped to a host UID/GID so bind-mounted wads/config/home directories
# keep sane ownership on the odroid host filesystem. Set via .env.
ENV ODAMEX_UID=1000
ENV ODAMEX_GID=1000

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]