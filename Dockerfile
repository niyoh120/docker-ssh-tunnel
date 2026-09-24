FROM alpine:3.21

# openssh-client : 隧道本体
# socat          : healthcheck 探活 + socket 模式
# tini           : 作为 PID1 正确转发信号（否则 docker stop 会把 ssh 硬杀，残留远端会话）
# busybox nc 不支持 -U，所以探活工具必须是 socat
RUN apk add --no-cache openssh-client socat tini \
 && mkdir -p /root/.ssh && chmod 700 /root/.ssh

COPY entrypoint.sh /usr/local/bin/docker-tunnel-entrypoint
COPY healthcheck.sh /usr/local/bin/docker-tunnel-healthcheck
RUN chmod 0755 /usr/local/bin/docker-tunnel-entrypoint /usr/local/bin/docker-tunnel-healthcheck

ENTRYPOINT ["/sbin/tini","--","/usr/local/bin/docker-tunnel-entrypoint"]
