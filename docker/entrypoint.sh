#!/bin/bash
# 1) 准备目录/属主  2) 首次运行写入 downloadDir=/downloads  3) 启动 server(内网端口) + caddy(对外端口, 可选 Basic Auth)
set -euo pipefail
log(){ echo "[entrypoint] $*"; }

PUID="${PUID:-10001}"; PGID="${PGID:-10001}"
CONFIG_DIR="${JM_CONFIG_DIR:-/config}"; DL_DIR="${JM_DOWNLOADS_DIR:-/downloads}"
export JM_INTERNAL_PORT="${JM_INTERNAL_PORT:-18080}" LISTEN_PORT="${LISTEN_PORT:-8080}"
mkdir -p "$CONFIG_DIR" "$DL_DIR"

# 运行用户解析 —— 让 docker 去适应 NAS，而不是反过来：
#   1) PUID/PGID 显式设置 → 听用户的（可用于强制 root: PUID=0）；
#   2) 否则从下载目录已有文件的属主自动推断（出现最多的 uid:gid，采样 200 个文件）；
#   3) 空目录 / 属主为 root → 回退 10001:10001。
# 把下载目录指向飞牛上已有漫画库时，无需手动查 uid，开箱即用；
# 新下载的文件属主就是库文件的主人，飞牛文件管理里可直接管理。
detect_dl_owner() {
  local top
  top="$(find "$DL_DIR" -maxdepth 3 -type f -printf '%U:%G\n' 2>/dev/null \
         | head -n 200 | sort | uniq -c | sort -rn | head -n 1 | awk '{print $2}')"
  if [ -n "$top" ]; then echo "$top"; else stat -c '%u:%g' "$DL_DIR" 2>/dev/null || true; fi
}
PUID="${PUID:-}"; PGID="${PGID:-}"
if [ -z "$PUID" ]; then
  detected_owner="$(detect_dl_owner)"
  det_uid="${detected_owner%%:*}"; det_gid="${detected_owner##*:}"
  if [ -n "$det_uid" ] && [ "$det_uid" != "0" ]; then
    PUID="$det_uid"
    [ -z "$PGID" ] && PGID="$det_gid"
    log "从下载目录文件属主自动推断运行用户 uid=$PUID gid=$PGID（显式设置 PUID/PGID 可覆盖）"
  fi
fi
PUID="${PUID:-10001}"
PGID="${PGID:-$PUID}"

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

# 权限自检：server 将以 uid=$PUID gid=$PGID 运行，提前验证下载目录可读可写。
# 典型场景：下载目录指向 NAS 上已有漫画库，文件属主是另一个用户；
# entrypoint 只修正顶层目录属主（大目录不递归），此时库存扫描会报 Permission denied。
# 注意：这里不自动 chown -R（大库慢 + 会改变宿主机文件属主），只给出明确指引。
as_run() {
  if [ "${#RUN_AS[@]}" -gt 0 ]; then "${RUN_AS[@]}" "$@"; else "$@"; fi
}
perm_err=""
if ! as_run touch "$DL_DIR/.jm_perm_probe" 2>/dev/null; then
  perm_err="write"
else
  as_run rm -f "$DL_DIR/.jm_perm_probe" 2>/dev/null || true
  # 抽查已有文件是否可读：布局固定为 $DL_DIR/<漫画>/<章节>.zip（3 层），
  # 取第一个不可读的即停，避免全量扫描大库
  perm_err="$(as_run find "$DL_DIR" -maxdepth 3 -type f ! -readable -print -quit 2>/dev/null || true)"
fi
if [ -n "$perm_err" ]; then
  log "=================================================================="
  if [ "$perm_err" = "write" ]; then
    log "ERROR: 容器内运行用户(uid=$PUID gid=$PGID)无法写入下载目录 $DL_DIR"
  else
    log "ERROR: 容器内运行用户(uid=$PUID gid=$PGID)无法读取下载目录 $DL_DIR 下的文件"
    log "ERROR: 首个不可读文件: $perm_err"
  fi
  log "原因：容器内运行用户与该目录部分文件的属主不一致；"
  log "      entrypoint 只修正顶层目录属主，不会递归修改大目录。"
  log "修复："
  log "  1) 在宿主机/NAS 上统一文件属主：chown -R $PUID:$PGID \"$DL_DIR\""
  log "  2) 如整库都不可读，检查 .env 里的 PUID/PGID 是否与文件属主一致"
  log "     （留空则自动从文件属主推断；宿主机执行 ls -n \"$DL_DIR\" 查看数字 uid gid）。"
  log "容器继续启动，但下载与库存扫描会报 Permission denied。"
  log "=================================================================="
else
  log "下载目录权限自检通过 ($DL_DIR 可读可写)"
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
