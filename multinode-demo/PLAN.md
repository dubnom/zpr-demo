# Multinode Demo Planning

This is the high level planning file. Sub-plans can be found in the
`work/` directory.


## 1. Set up the OCI environment

We need opentofu configuration files that set up our OCI compute with
two hosts. (NOTE: a previous version of the plan called for three OCI
hosts).

  - All hosts are ubuntu linux 24.04.

  - I must be able to SSH into each of them from outside OCI.

  - The hosts need to be able to communicate with each other using IP.

  - The hosts need to be able to open TCP and UDP connections outside of OCI.

  - The IDs or "names" of the hosts are "webserver" and "node".

  - The host named "node" must allow TCP and UDP access inbound to port 5000
    from the outside.

We should take inspriation from and/or copy the OpenTofu files that are used in
the `iot-demo` (see `../iot-demo/`).

> **See [`tf-setup-plan.md`](work/tf-setup-plan.md)** — the implementation plan for the
> OpenTofu config that stands up these three hosts (Ubuntu 24.04) on OCI: network,
> security lists, per-host cloud-init, and static TUN setup. Covers getting
> SSH-able hosts with `tun9` configured; ZPR components (§3) are deferred.
>
> **See [`tf-no-vs-plan.md`](work/tf-no-vs-plan.md)** — follow-up that drops the `vs`
> host from `oci-compute/`, moving valkey + the visa service to the local docker
> env (§5/§6). Supersedes the three-host count above: OCI now runs two hosts
> (`webserver`, `node`).


## 2. Configure the NON-ZPR components on each host (OCI ENV)

* All hosts need SSHD running.
* All hosts should have `tmux` installed.


### 2.1 host "webserver"

This host will run nginx and serve HTTP on port 80. The index page should be
text and include "hello from OCI". This is a placeholder -- will be more fancy
later.


## 3. Configure the ZPR components on each host (OCI ENV)

- The ZPR binaries can be found in `bin/`.
- The configurations files for each ZPR component can be found in
  `zpr-conf/confs`. 
- All the `adapter-*` configs need the `node_addr` set based on the
  addresses assigned in `tofu output`.  The `node_addr` is the address
  of the "node" host. 
- The `nodeN-*` configs need `self_addr` set.
- Each configuration file references one or more files in
  `zpr-conf/include` using the path `include/<some-file>`. So on the
  host we need an `include` directory at same level as the location of
  the configuration file.

The ZPR `ph` binary logs to stdout. So in order to preseve the log
redirect that to a local file.

For inspiration examine what the `iot-demo` does to get the binaries
running.


### 3.1 host "webserver"

This is running an adapter. That is our `ph` code, launched in adapter mode.
Launch like so: `./ph adapter -c /path/to/adapter-web0-conf.toml`.

The config file is `adapter-web0-conf.toml`



### 3.2 host "node"

This is running a node. That is our `ph` code, launched in node mode.
Launch like so: `./ph node -c /path/to/node0-conf.toml`.

The config file is `node0-conf.toml`


## 4. Startup Order (OCI ENV)

The startup order for the OCI cloud components is:

1. On node host, ensure ZPR TUN address is configured.
2. Start the node

3. On web host, ensure that the ZPR TUN address is configured.
4. Start the web service 
5. Start the web service adapter


## 5. Set up the local (docker) environment

For the docker environment we will take inspiration from the older
`containerized-demo`. See `../containerized-demo/docker`.

The big picture: In docker we fire up three containers. A node, the visa
service, and a web server. The node must be reachable from outside docker on TCP
and UDP port 5000. The `ph` process on the node container will need to be able
to open TCP/UDP connections to the outside world. And we need to be able to ssh
into or just run a process in a TTY connected to the visa service container so
we can use the `vs-admin` tool. There needs to be a straightforward way for the
person running the demo (who launched the docker) to be able to view the the log
(the output) of the node `ph` process and the visa service `vs` process.

> **See [`work/docker-configure-run-zpr.md`](work/docker-configure-run-zpr.md)** — the
> implementation plan for §5–8. Orchestration is **docker-compose** (containers,
> network, static IPs, published ports, tun9 caps — reusing `containerized-demo`)
> plus a thin `local-compute/deploy-docker.sh` for the dynamic host-side steps
> (render `@@…@@` templates, generate `vs_keys.toml`, compile the policy) that
> don't fit compose. Mirrors the OCI declarative/imperative split
> (`work/tf-configure-run-zpr.md` + `deploy-zpr.sh`).
>
> **See [`work/docker-configure-run-zpr-steps.md`](work/docker-configure-run-zpr-steps.md)** —
> the ordered, task-by-task breakdown derived from the plan above; all steps
> completed and marked DONE.


## 6. Per Container Setup (DOCKER)

The three containers:

1. The Node. Name = `node1`.
2. The Visa Service. Name = `vs`.
3. The Web Service. Name = `web1`.

**Orchestration.** One image (ubuntu 24.04 + tmux + nginx + valkey + the `bin/`
binaries baked in) is reused by all three containers, differing only by
entrypoint + mounted config. `docker-compose.yml` defines the containers,
network, static IPs, published ports, and tun9 capabilities. The rendered
configs, the `include/` dir, the compiled policy `multinode-demo.bin2`, the
`vs_keys.toml`, and a `logs/` dir come in as **mounted volumes** — so a
re-deploy re-renders and restarts without rebuilding the image. This reuses the
`containerized-demo/docker` structure. See `work/docker-configure-run-zpr.md`.

* Each container is ubuntu 24.04 (just like our OCI compute instances).

* Each container should have tmux installed.

* Container `web1` need nginx, and needs to have it index page set to a file
  installed into the container that returns text which includes "hello from
  on-prem". This is a place holder. Create the index file locally and it will be
  updated later.

* Inside the container network, the containers need to be able to talk to each
  other over IP. Use a user-defined bridge network (e.g. `zpr-local`) with
  **static IPs** for `node1`/`vs`/`web1` — the adapter configs need `node1`'s
  address baked in (see §7), so it must be stable. The legacy `multinode-demo`
  uses `172.30.0.0/24`; organization networks derive their `/24` from the
  profile's substrate addresses and must not overlap other running networks.

* Only the `node1` container needs to be reachable from the host OS: publish
  port `5000` for **both TCP and UDP** (`5000:5000/tcp` and `5000:5000/udp`).
  All containers get outbound TCP/UDP to the internet for free via the default
  bridge NAT — no extra config.

* `node1`, `vs`, and `web1` each run a `ph` process bound to `tun9` (their
  configs set `tun_if = "tun9"`), so each container needs a TUN device:
  `cap_add: NET_ADMIN`, `devices: /dev/net/tun`, `privileged: true`, and `tun9`
  created in the entrypoint (as in `containerized-demo/docker/docker-node` and
  `docker-vs` entrypoints).

* The `vs` container requires `ValKey` running and listening on `127.0.0.1` port
  `6379`. There is no systemd in a container, so "as a service" means: launched
  (backgrounded) by the `vs` entrypoint. Install path: `apt-get install
  valkey-server` is not in Ubuntu 24.04's default repos — reuse
  `containerized-demo`'s from-source build in the Dockerfile unless a packaged
  option is confirmed at build time.


## 7. Configure the ZPR components on each host (DOCKER)


- The ZPR binaries can be found in `bin/`.
- The configurations files for each ZPR component can be found in
  `zpr-conf/confs`. 
- Each configuration file references one or more files in
  `zpr-conf/include` using the path `include/<some-file>`. So in the
  container we need an `include` directory at same level as the location of
  the configuration file.

**Address model.** The `@@…@@` sentinels in the templates are not all the same
node1 address, and one token means different things in different files. The
`deploy-docker.sh` script substitutes them and must fail loud on any leftover
`@@…@@` (same idiom as `deploy-zpr.sh`). Sources:

| sentinel / field | meaning | value source |
|---|---|---|
| `@@NODE1_ADDR@@` (`adapter-vs`, `adapter-web1`) | node1's **docker-internal** IP — in-network clients reach node1 directly | the compose static IP for `node1` |
| `@@NODE1_EXT_ADDR@@` (`adapter-bob`, policy `.zplc` n1 substrate) | node1 as reached **from OCI** = externally reachable host IP + published 5000 | required `NODE1_EXT_ADDR`; inbound TCP+UDP 5000 must reach Docker node1 |
| `@@NODE0_PUBLIC_ADDR@@` (policy `.zplc` n0 substrate) | **OCI node0's PUBLIC IP** so on-prem can reach it across the internet | `tofu -chdir=../oci-compute output -json public_ips \| jq -r .node` |

Note the policy's `@@NODE0_PUBLIC_ADDR@@` is deliberately a distinct token from
the OCI `adapter-web0-conf` template's `@@NODE0_ADDR@@` (node0's *private* IP,
substituted by `deploy-zpr.sh`) — same host, different addresses, so they must
never collide. This does mean the docker deploy has a cross-directory dependency
on the OCI tofu state (`../oci-compute`) to get node0's public IP.

**Host-side client (`bob`).** `adapter-bob-conf.toml.template` is *not* a container —
it is the operator's own client (browser/curl side), run on the host OS to reach
the ZPR web services. `deploy-docker.sh` renders it (using `@@NODE1_EXT_ADDR@@`)
and leaves it on the host alongside `client.key`.

**Policy compilation** runs on the **host** (it needs `bin/zplc` and the
`include/` public keys the `.zplc` references as `../include/...`). The resulting
`multinode-demo.bin2`, plus the freshly generated `vs_keys.toml`, are mounted
into the `vs` container; `client.key` stays on the host (see §7.3).

**Logging.** Just as in OCI, each `ph`/`vs` runs inside a detached `tmux` with
output `tee`'d to a file — but the file lives on a **mounted `logs/` volume**
(`.../$name.log`) so the operator can `tail -f local-compute/logs/*.log` from the
host without `docker exec`. The processes are launched via `docker exec` into
tmux (mirrors `start_ph()` in `deploy-zpr.sh`).


### 7.1 Container `web1`

This is running an adapter. That is our `ph` code, launched in adapter mode.
Launch like so: `./ph adapter -c /path/to/adapter-web1-conf.toml`.

The config file is `adapter-web1-conf.toml`



### 7.2 Container "node1"

This is running a node. That is our `ph` code, launched in node mode.
Launch like so: `./ph node -c /path/to/node1-conf.toml`.

The config file is `node1-conf.toml`



### 7.3 Container "vs"

This is running an adapter. That is our `ph` code, launched in adapter mode. The
config file is: `adapter-vs-conf.toml`.

The visa service also needs `vs_keys.toml` file to be in same directory as the
`vs` binary.

This file needs to be created on each deploy. To create the file:

```bash
./vsapikey create --init readwrite client /path/to/vs_keys.toml >/path/to/client.key
```

After this runs:
- `/path/to/vs_keys.toml` is the `vs_keys.toml` required by the visa service.

- `/path/to/client.key` is the client key token required to administer the
  running visa service. This needs to be saved and the user told where it is. It
  does not go into the container; it remains on host OS.

The visa service needs the compiled policy. The policy file itself is a template
that needs to know the 'external' address of the `node1` container.

The policy template is here: `zpr-conf/admin/multinode-demo.zplc.template`.

Once the variables have been substituded, the file needs to be named
`multinode-demo.zplc` and then the policy can be compiled like so:

```bash
bin/zplc --config /path/to/multinode-demo.zplc /path/to/multinode-demo.zpl
```

The above commands writes the compiled policy file, `multinode-demo.bin2` to the
working directory. This bin2 file must be accessible to the `vs` process running
in the visa service container.

Launch the visa service like so:

```
./vs --clear-state path/to/multinode-demo.bin2
```

Like `ph` the `vs` writes its logging output to the console.


## 8. Startup Order (DOCKER)

Steps 1–5 below are `docker exec` launches into a detached `tmux` (with `tee` to
the mounted `logs/` volume). Before any of them, `deploy-docker.sh` does the
host-side prep:

0. **On the host:** render every `*.template` → concrete config (fail on any
   leftover `@@…@@`), generate `vs_keys.toml` + `client.key`, compile the policy
   → `multinode-demo.bin2`. Then `docker compose up -d` — the entrypoints bring
   up `tun9`, `valkey` (in `vs`), and `nginx` (in `web1`).

The startup order for the ZPR processes is then:

1. Start the `ph` in `node1`. Give it a few seconds to start up.

2. Start the `vs` process in `vs` container.

3. Start the `ph` (adapter) process in `vs` container.

4. Wait 6 seconds for things to settle, then:

5. Start the `ph` (adapter) process in the `web1` container. (nginx is already
   up from the entrypoint — verify it's serving before starting the adapter.)








