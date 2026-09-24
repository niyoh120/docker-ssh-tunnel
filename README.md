# docker-ssh-tunnel

Access remote Docker daemons over SSH, with no agent installed on the nodes and no Docker port exposed to the network.

Every container-update checker (WUD, Diun, freshdock, docker-updater) talks to Docker through SDKs that only understand `unix://`, `tcp://` and `http://` endpoints. `DOCKER_HOST=ssh://` is implemented by the Docker **CLI** alone, so SDK-based tools can never dial SSH themselves. This image closes that gap: it forwards a remote `/var/run/docker.sock` to a local socket or TCP port, so any tool can consume it as an ordinary Docker endpoint.

```
checker / CLI  ──▶  local TCP 2375 (or a unix socket)  ──ssh──▶  node:/var/run/docker.sock
```

## What you get

- `Dockerfile` — ~15 MB image: alpine + openssh-client + socat + tini
- `entrypoint.sh` — builds the forwarding command from a node env file
- `healthcheck.sh` — end-to-end probe (asks the remote daemon's `/_ping`, no Docker CLI required)
- `docker-compose.example.yml` — one tunnel container per node, plus WUD as the consumer
- `systemd/` — template unit for running the tunnels on a host instead of in containers
- `bin/` — a health checker for a fleet of tunnels and a node-list generator for Coolify

## Usage

### Node configuration

One env file per node:

```sh
# /etc/docker-tunnel/nodes/node-a.env
SSH_USER=root
SSH_HOST=node-a.example.com
SSH_PORT=22
SSH_KEY=/root/.ssh/docker_tunnel_ed25519
```

Key-based auth must work, and the key must be able to read `/var/run/docker.sock` on the node.

### Run a tunnel

```sh
docker run -d --name tunnel-node-a \
  -p 127.0.0.1:2375:2375 \
  -e TUNNEL_MODE=tcp \
  -e SSH_HOST=node-a.example.com \
  -e SSH_USER=root \
  -e SSH_KEY=/key/id_ed25519 \
  -v /path/to/key:/key/id_ed25519:ro \
  ghcr.io/niyoh120/docker-ssh-tunnel:latest
```

Then point anything at it:

```sh
docker -H tcp://127.0.0.1:2375 version
```

`TUNNEL_MODE=socket` forwards to `<SOCKET_DIR>/<node>.sock` instead of a TCP port. Prefer the TCP mode inside containers: consumers then use plain `HOST`+`PORT`, socket permissions between containers never come up, and recreating the socket cannot break a bind mount.

### Consuming it from WUD

```yaml
services:
  wud:
    image: getwud/wud:latest
    environment:
      WUD_WATCHER_NODEA_HOST: tunnel-node-a
      WUD_WATCHER_NODEA_PORT: "2375"
```

Never use WUD's own `docker`/`docker-compose` triggers against containers managed by a platform like Coolify. Those recreate containers outside the platform's control, losing its labels, networks and state. Send updates through the platform's own deploy API instead.

## Node requirements

| sshd setting | Needed | Why |
|---|---|---|
| `AllowStreamLocalForwarding` | `yes` (default) | otherwise stream-local requests are refused outright |
| `AllowTcpForwarding` | must not be `no` | sshd gates `permit_port_forwarding_flag` on it, so stream-local requests are denied even when `AllowStreamLocalForwarding yes` |

When the second one is missing, the tunnel connects and the local port listens, yet every connection dies immediately. The node's sshd log says:

```
Received request to connect to path /var/run/docker.sock, but the request was denied.
```

Most distributions ship the defaults (commented `#AllowTcpForwarding yes`), so nodes hardened to `AllowTcpForwarding no` are the ones that fail.

## Design notes

- `ExitOnForwardFailure=yes` — makes ssh exit when the forward cannot be established, so a supervisor restarts it instead of leaving a live process with a dead forward.
- `ServerAliveInterval=15` with `ServerAliveCountMax=3` — half-open connections are torn down within ~45 s.
- `StreamLocalBindUnlink=yes` plus removing the socket before start — a stale socket file is harder to diagnose than a missing one.
- One tunnel per process (container or systemd instance). Per-node isolation keeps one node's failure local and comes with supervision for free.
- `tini` as PID 1, so `docker stop` reaches ssh and the remote session is cleaned up.

## Health checking

Check the tunnel end to end, never just `is-active` or "is the port open":

```sh
docker exec tunnel-node-a /usr/local/bin/docker-tunnel-healthcheck   # exit 0 when the remote daemon answers
bin/docker-tunnel-health --heal                                      # fleet check, restarts unreachable tunnels
```

A tunnel going down is **not** the same as its containers disappearing. Socket-scanning tools read an unreachable node as "everything was removed" and may emit removal events, so health-check first and mark unreachable nodes as unknown.

## Security

The forwarded socket is the Docker control plane: whoever can reach it has root-equivalent power on that node. The image keeps the port inside the container network (`expose`, never `publish`), and the SSH key should be dedicated to this purpose, mode `0600`, with `authorized_keys` restricted by `from="<hub-ip>"`.

## License

MIT
