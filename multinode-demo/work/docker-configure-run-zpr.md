# Plan: Configure & Run ZPR in the local docker env (PLAN.md §5–8)

Stands up a local two-node ZPR network in six containers: `node0`, `node1`,
`vs`, `web0`, `web1`, and `alice`. All peer substrate addresses are internal
to the Docker bridge; no OCI resources or public IPs are required.

## Compose alone? A script alone? No — both.

- **`docker-compose.yml` owns the declarative infra** — containers, the
  user-defined bridge with static IPs, node1's host-published port 5000,
  `tun9` capabilities, and config/log mounts.
- **`local-compute/deploy-docker.sh` owns runtime setup** — render local
  addresses, generate `vs_keys.toml`, compile policy, start both nodes and VS,
  then wait for the authenticated peer edge before starting web1's adapter.

Entrypoints stay thin: bring up `tun9`, start `valkey` (vs), start `nginx`
(web1). The ZPR process launches are done by the script via `docker exec` so
their logs `tee` to a host-visible volume (see Logging).

## Image

One image, reused by all six containers (like `containerized-demo`):
Ubuntu 24.04 + `tmux` + `nginx` + Redis + the `bin/` binaries baked in.
Binaries are large (`ph` ~200 MB, `vs` ~220 MB) but this is local — no network
push, so baking them in is fine and keeps re-deploys volume-only (no rebuild).

Redis is used as the Redis-protocol-compatible disposable local state store.

## Address model — the crux

See the table in PLAN.md §7. The three substituted values and their sources:

| sentinel | value | source |
|---|---|---|
| `@@NODE0_ADDR@@` | node0 substrate IP | `172.30.0.13` in Compose |
| `@@NODE1_ADDR@@` | node1 substrate IP | `172.30.0.10` in Compose |
| `@@NODE1_EXT_ADDR@@` | node1 as reached by host-side bob | `127.0.0.1`, used only by bob |

Node configs pin each peer's Noise certificate and bootstrap the same policy
`link_id`; authenticated Visa Service topology later reconciles the peer.

Files and where each renders / lands:
- `adapter-vs-conf` → `@@NODE0_ADDR@@`; `adapter-web1-conf` → `@@NODE1_ADDR@@`.
- `node0-conf.toml` and `node1-conf.toml` → reciprocal bootstrap peer and
  trusted certificate entries.
- `multinode-demo.zplc.template` → both internal node addresses, compiled on
  host → `multinode-demo.bin2` mounted into `vs`.
- `adapter-client-conf.toml.template` → `@@NODE1_EXT_ADDR@@` → stays on **host**
  (operator's client; not a container), next to `client.key`.

## Local startup

Build Linux/amd64 binaries and the image, then run
`./local-compute/deploy-docker.sh`. The script starts node0, node1, and VS with
the VS adapter on node0. Both nodes bootstrap the pinned peer entry before
control-plane connectivity; the deploy waits for both PH link summaries to
report `Active`, then starts web0 and Alice adapters. The PremWeb adapter is
optional (`START_PREMWEB_ADAPTER=1`). The final smoke test requires Alice's HTTP
request to OciWeb to cross node1 → node0. A timeout prints node logs rather
than claiming readiness.

## Layout & logging

- Mounts per container: rendered config(s) + `include/` (only the referenced
  files) + a shared `logs/` dir; `vs` also gets `vs_keys.toml` +
  `multinode-demo.bin2`.
- Logs: `tail -f local-compute/logs/*.log` on the host (node1, vs, adapters) —
  no `docker exec` needed. Also attach live: `docker exec -it <c> tmux attach`.

## Checklist

- [x] Dockerfile (image with binaries + valkey + nginx + tmux)
- [x] `docker-compose.yml` (network, static IPs, ports, tun caps, mounts)
- [x] per-container entrypoints (tun9 / valkey / nginx)
- [x] `local-compute/deploy-docker.sh` (steps 0–5 above)
- [x] web1 index file ("hello from on-prem")
- [x] README section (mirror the OCI runbook)

## Verify (once implemented)

`make ZPR_ROOT=../.. linux-amd64` → `docker build --platform linux/amd64 -t
zpr-multinode .` → `./local-compute/deploy-docker.sh` → verify both nodes show
the other node as `(Active)` and confirm Alice receives OciWeb over the peer.
