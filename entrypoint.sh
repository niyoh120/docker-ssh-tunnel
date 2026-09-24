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

# 密钥可以走文件，也可以走环境变量 —— 环境变量形式省掉在平台侧挂载文件（Coolify/compose 等
# 只需注入一个变量即可）。SSH_KEY_B64 优先，写入后立即降到 0600。
if [ -n "${SSH_KEY_B64:-}" ]; then
  SSH_KEY=/tmp/tunnel_key
  umask 077
  printf '%s' "$SSH_KEY_B64" | base64 -d > "$SSH_KEY" 2>/dev/null \
    || { echo "SSH_KEY_B64 is not valid base64" >&2; exit 1; }
  chmod 600 "$SSH_KEY"
  grep -q 'BEGIN .*PRIVATE KEY' "$SSH_KEY" 2>/dev/null \
    || { echo "SSH_KEY_B64 does not decode to a private key" >&2; exit 1; }
fi

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

# ExitOnForwardFailure : socket/端口绑不上就退出，不留"活着但不转发"的假活会话
# StreamLocalBindUnlink: 允许覆盖残留 socket
# ServerAlive*         : 半开连接 ~45s 内被发现并重建
SSH_OPTS="-N -T -o BatchMode=yes \
-o ExitOnForwardFailure=yes \
-o StreamLocalBindUnlink=yes \
-o ServerAliveInterval=15 \
-o ServerAliveCountMax=3 \
-o TCPKeepAlive=yes \
-o ConnectTimeout=10 \
-o StrictHostKeyChecking=accept-new \
-o UserKnownHostsFile=/root/.ssh/known_hosts \
-i $SSH_KEY \
-p $SSH_PORT"

# 失败后的重试策略（RETRY_DELAY=0 则直接退出，交给编排层 restart 策略）：
#   容器内重试的价值不只是"少重启"——闪退容器的日志在编排层基本读不到（docker logs 只对
#   运行中的容器可查），而对端 sshd 的 fail2ban 会按"每分钟一次"的失败频率把本机拉黑。
#   退避到分钟级后，既保住日志可读性，也把失败频率压到封禁阈值以下。
RETRY_DELAY=${RETRY_DELAY:-30}
MAX_DELAY=${MAX_DELAY:-300}

if [ "$RETRY_DELAY" -gt 0 ] 2>/dev/null; then
  delay=$RETRY_DELAY
  while :; do
    started=$(date +%s)
    set +e
    # shellcheck disable=SC2086
    ssh $SSH_OPTS $FORWARD "$SSH_USER@$SSH_HOST"
    rc=$?
    set -e
    elapsed=$(( $(date +%s) - started ))
    # 会话稳定存活过一段时间 → 重置退避，避免偶发抖动后一直用最大间隔
    if [ "$elapsed" -ge 300 ]; then delay=$RETRY_DELAY; fi
    echo "[docker-tunnel] ssh 退出 rc=$rc（会话存活 ${elapsed}s），${delay}s 后重试"
    sleep "$delay"
    delay=$(( delay * 2 ))
    [ "$delay" -gt "$MAX_DELAY" ] && delay=$MAX_DELAY
  done
fi

# shellcheck disable=SC2086
exec ssh $SSH_OPTS $FORWARD "$SSH_USER@$SSH_HOST"
