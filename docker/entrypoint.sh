#!/bin/bash
# 1) 准备目录/属主  2) 首次运行写入 downloadDir=/downloads  3) 启动 server(内网端口) + caddy(对外端口, 可选 Basic Auth)
set -euo pipefail
log(){ echo "[entrypoint] $*"; }

PUID="${PUID:-10001}"; PGID="${PGID:-10001}"
CONFIG_DIR="${JM_CONFIG_DIR:-/config}"; DL_DIR="${JM_DOWNLOADS_DIR:-/downloads}"
export JM_INTERNAL_PORT="${JM_INTERNAL_PORT:-18080}" LISTEN_PORT="${LISTEN_PORT:-8080}"
mkdir -p "$CONFIG_DIR" "$DL_DIR"

# 首次运行：没有 config.json 时写一个最小配置，其余字段由程序按默认值补齐
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  log "首次运行，初始化 config.json (downloadDir=$DL_DIR)"
  printf '{\n  "downloadDir": "%s",\n  "exportDir": "%s/_export"\n}\n' "$DL_DIR" "$DL_DIR" > "$CONFIG_DIR/config.json"
fi

RUN_AS=()
if [ "$(id -u)" = "0" ]; then
  if chown "$PUID:$PGID" "$CONFIG_DIR" 2>/dev/null; then
    chown -R "$PUID:$PGID" "$CONFIG_DIR" 2>/dev/null || true
    # 下载目录只修正顶层，避免大目录每次启动全量 chown
    chown "$PUID:$PGID" "$DL_DIR" 2>/dev/null || true
    RUN_AS=(gosu "$PUID:$PGID")
    log "以 uid=$PUID gid=$PGID 运行"
  else
    log "无法 chown（rootless?），以当前用户运行"
  fi
fi

# 鉴权：设置 AUTH_USER + AUTH_PASSWORD 即开启 Basic Auth
CADDYFILE=/etc/caddy/Caddyfile
if [ -n "${AUTH_USER:-}" ] && [ -n "${AUTH_PASSWORD:-}" ]; then
  export AUTH_HASH; AUTH_HASH="$(caddy hash-password --plaintext "$AUTH_PASSWORD")"
  CADDYFILE=/etc/caddy/Caddyfile.auth
  log "Basic Auth 已开启 (user=$AUTH_USER)"
else
  log "未设置 AUTH_USER/AUTH_PASSWORD，WebUI 无鉴权（请勿直接暴露公网）"
fi
unset AUTH_PASSWORD

cd /app
JM_PORT="$JM_INTERNAL_PORT" "${RUN_AS[@]}" /app/server &
SERVER_PID=$!
"${RUN_AS[@]}" caddy run --adapter caddyfile --config "$CADDYFILE" &
CADDY_PID=$!
trap 'kill -TERM $SERVER_PID $CADDY_PID 2>/dev/null' TERM INT
# 任一进程退出则整体退出，交给 Docker restart 策略
wait -n $SERVER_PID $CADDY_PID; rc=$?
log "子进程退出 (rc=$rc)，停止容器"
kill -TERM $SERVER_PID $CADDY_PID 2>/dev/null || true
wait || true
exit $rc
