#!/usr/bin/env bash
# 冒烟测试：启动镜像，验证 /health、WebUI、/config、downloadDir、healthcheck、Basic Auth
set -euo pipefail
IMG="${1:?usage: smoke-test.sh IMAGE}"
D="$(mktemp -d)"; P=18888; PA=18889
cleanup(){ docker rm -f jm-smoke jm-smoke-auth >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail(){ echo "FAIL: $*"; docker logs jm-smoke 2>&1 | tail -50 || true; exit 1; }

docker run -d --name jm-smoke -p $P:8080 -v "$D/config:/config" -v "$D/downloads:/downloads" "$IMG" >/dev/null
for i in $(seq 1 30); do curl -fsS localhost:$P/health >/dev/null 2>&1 && break; sleep 2; done
curl -fsS localhost:$P/health | grep -q '"ok"' || fail "/health"; echo "OK /health"
curl -fsS localhost:$P/ | grep -qi '<html' || fail "WebUI"; echo "OK WebUI /"
curl -fsS localhost:$P/config | grep -q '"downloadDir":"/downloads"' || fail "downloadDir"; echo "OK downloadDir=/downloads"
test -f "$D/config/config.json" || fail "config 未持久化"; echo "OK config 持久化到卷"
for i in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' jm-smoke); [ "$s" = healthy ] && break; sleep 3; done
[ "$s" = healthy ] || fail "healthcheck=$s"; echo "OK healthcheck=healthy"

docker run -d --name jm-smoke-auth -p $PA:8080 -e AUTH_USER=u -e AUTH_PASSWORD=p "$IMG" >/dev/null
for i in $(seq 1 30); do curl -fsS localhost:$PA/health >/dev/null 2>&1 && break; sleep 2; done
[ "$(curl -s -o /dev/null -w '%{http_code}' localhost:$PA/)" = 401 ] || fail "auth 未生效"
[ "$(curl -s -o /dev/null -w '%{http_code}' -u u:p localhost:$PA/)" = 200 ] || fail "auth 正确密码失败"
echo "OK Basic Auth (无凭据 401 / 正确凭据 200)"
echo "ALL PASSED"
