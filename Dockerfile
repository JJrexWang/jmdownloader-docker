# syntax=docker/dockerfile:1.7
# jmdownloader-docker：基于 JJrexWang/jmdownloader-enhance 的 headless server 镜像
#
# 上游源码获取方式：构建时按 commit SHA 从 GitHub 下载 tarball（不再用 git submodule）。
# 跟进上游修复 = 只改下面 UPSTREAM_SHA 这一行，推送后 CI 自动重建镜像。
# （历史原因：仓库里还留着 upstream submodule 指针，但构建已不再使用它。）

ARG RUST_IMAGE=rust:1.88-bookworm
ARG CADDY_VERSION=2.8.4
ARG UPSTREAM_REPO=JJrexWang/jmdownloader-enhance
ARG UPSTREAM_SHA=b364c1d11be5081975bed35ed80d102191015b88

FROM ${RUST_IMAGE} AS builder
ARG UPSTREAM_REPO
ARG UPSTREAM_SHA
# tauri 作为 lib 依赖，其 build script 需要 gtk/webkit 头文件（只在构建期需要，不进运行镜像）
RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libssl-dev zlib1g-dev ca-certificates \
      libgtk-3-dev libsoup-3.0-dev libwebkit2gtk-4.1-dev librsvg2-dev libayatana-appindicator3-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
# 下载上游指定 commit 的源码包并解开（--strip-components 去掉 tarball 顶层目录）
ADD https://github.com/${UPSTREAM_REPO}/archive/${UPSTREAM_SHA}.tar.gz /tmp/upstream.tgz
RUN mkdir -p /tmp/upstream-src \
 && tar xzf /tmp/upstream.tgz -C /tmp/upstream-src --strip-components=1 \
 && rm /tmp/upstream.tgz \
 && cp -r /tmp/upstream-src/src-tauri ./src-tauri \
 && cp -r /tmp/upstream-src/src-tauri/webui /webui \
 && rm -rf /tmp/upstream-src
WORKDIR /build/src-tauri
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/src-tauri/target \
    cargo build --release --locked --bin server \
 && cp target/release/server /server

FROM caddy:${CADDY_VERSION} AS caddy

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3 zlib1g ca-certificates curl gosu tini tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 jm && useradd --system --uid 10001 --gid 10001 --home-dir /config jm
COPY --from=builder /server /app/server
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY --from=builder /webui /app/webui
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/Caddyfile docker/Caddyfile.auth /etc/caddy/
RUN chmod +x /usr/local/bin/entrypoint.sh && mkdir -p /config /downloads

# PUID/PGID 不在这里设默认值：留空时 entrypoint 会从下载目录已有文件的
# 属主自动推断（docker 去适应 NAS），显式 -e PUID=xxx 可覆盖。
ENV JM_CONFIG_DIR=/config \
    JM_DOWNLOADS_DIR=/downloads \
    LISTEN_PORT=8080 \
    RUST_LOG=info \
    XDG_DATA_HOME=/tmp XDG_CONFIG_HOME=/tmp
EXPOSE 8080
VOLUME ["/config", "/downloads"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${LISTEN_PORT}/health" || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
