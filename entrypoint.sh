#!/bin/sh
# docker-tunnel 容器入口：把某个节点的 docker.sock 通过 SSH 暴露到本容器
#
#   TUNNEL_MODE=tcp    → 本容器 0.0.0.0:2375 背后是远端 /var/run/docker.sock
#                        （推荐：同 compose 网络里的 WUD 直接用 HOST+PORT，无需共享卷）
#   TUNNEL_MODE=socket → 在共享卷里生成 <node>.sock
#                        （适合只能吃 socket 路径的工具，注意要挂目录而不是单个文件）
#
# 用法: ENTRYPOINT <node-name>   节点参数从 $ENV_FILE 或环境变量读
set -eu

NODE=${1:?usage: docker-tunnel-entrypoint <node-name>}
ENV_FILE=${ENV_FILE:-/etc/docker-tunnel/nodes/$NODE.env}
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

: "${SSH_HOST:?SSH_HOST is required (set it in $ENV_FILE or the environment)}"
SSH_USER=${SSH_USER:-root}
SSH_PORT=${SSH_PORT:-22}
SSH_KEY=${SSH_KEY:-/root/.ssh/id_ed25519}
TUNNEL_MODE=${TUNNEL_MODE:-tcp}
LOCAL_PORT=${LOCAL_PORT:-2375}
SOCKET_DIR=${SOCKET_DIR:-/tunnels}

[ -r "$SSH_KEY" ] || { echo "SSH key not readable: $SSH_KEY" >&2; exit 1; }

case "$TUNNEL_MODE" in
  tcp)
    FORWARD="-L 0.0.0.0:${LOCAL_PORT}:/var/run/docker.sock"
    ;;
  socket)
    mkdir -p "$SOCKET_DIR"
    rm -f "$SOCKET_DIR/$NODE.sock"
    FORWARD="-L ${SOCKET_DIR}/${NODE}.sock:/var/run/docker.sock"
    ;;
  *)
    echo "TUNNEL_MODE must be tcp or socket (got: $TUNNEL_MODE)" >&2
    exit 2
    ;;
esac

# known_hosts 只在这台节点第一次连接时生成一次；host key 变了要人工确认，不要静默接受
if [ ! -s /root/.ssh/known_hosts ] || ! ssh-keygen -F "$SSH_HOST" -f /root/.ssh/known_hosts >/dev/null 2>&1; then
  ssh-keyscan -p "$SSH_PORT" -H "$SSH_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true
  chmod 600 /root/.ssh/known_hosts 2>/dev/null || true
fi

echo "[docker-tunnel] node=$NODE mode=$TUNNEL_MODE user=$SSH_USER@$SSH_HOST:$SSH_PORT key=$SSH_KEY"

# ExitOnForwardFailure : socket/端口绑不上就退出（交给 docker restart 策略），不留"活着但不转发"的假活会话
# StreamLocalBindUnlink: 允许覆盖残留 socket
# ServerAlive*         : 半开连接 ~45s 内被发现并重建
# shellcheck disable=SC2086
exec ssh -NT \
  -o BatchMode=yes \
  -o ExitOnForwardFailure=yes \
  -o StreamLocalBindUnlink=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o TCPKeepAlive=yes \
  -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/root/.ssh/known_hosts \
  -i "$SSH_KEY" \
  -p "$SSH_PORT" \
  $FORWARD \
  "$SSH_USER@$SSH_HOST"
