#!/bin/sh
# 端到端探活：不是看端口在不在，而是穿过隧道问远端 dockerd 的 /_ping。
# busybox nc 不支持 -U，所以用 socat；docker CLI 也不需要进镜像。
set -u

TUNNEL_MODE=${TUNNEL_MODE:-tcp}
LOCAL_PORT=${LOCAL_PORT:-2375}
SOCKET_DIR=${SOCKET_DIR:-/tunnels}
PING='GET /_ping HTTP/1.0\r\n\r\n'
TIMEOUT=5

if [ "$TUNNEL_MODE" = socket ]; then
  NODE=${1:?socket mode needs the node name as argument}
  TARGET="UNIX-CONNECT:$SOCKET_DIR/$NODE.sock"
else
  TARGET="TCP:127.0.0.1:$LOCAL_PORT"
fi

resp=$(printf "$PING" | timeout "$TIMEOUT" socat - "$TARGET" 2>/dev/null || true)
case "$resp" in
  *"200 OK"*) exit 0 ;;
  *) echo "unhealthy: no HTTP 200 from remote dockerd via $TARGET"; exit 1 ;;
esac
