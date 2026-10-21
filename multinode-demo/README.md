# Multinode Demo

## Contents

- `bin` - Binaries to run for the demo
- `commands` - Operator commands for driving a running demo (see below).
- `local-compute` - Setup code for the local ("on prem") containers.
- `oci-compute` - OpenTofu setup for the remote (OCI cloud) instances.
- `zpr-conf` - All the ZPR config files, certificates, policy, etc.

## Handy commands (`commands/`)

Organization provisioning defines `SimulatorControlService` by authenticated
`simulator-control` adapter identity only. Do not constrain this provider to the
adapter's requested fixed address: Visa may assign a dynamic address, and that
constraint denies machine-controller traffic even when every node is synchronized.

Profiles with `business_simulation: true` provision seven persistent business
provider identities using the dashboard's `scripts/business-workloads.sh`.
Private keys stay under the organization runtime's `business-keys/`; only public
keys enter runtime includes and the compiler bootstrap registry. Repeated
preparation preserves existing keys. This is Simulator provisioning, not a
production operator dependency. See the dashboard's Great Lakes organization
guide for the separate provider host, service workflows, and access matrices.
Source changes alone do not deploy or start these providers.

Once both environments are deployed, `commands/` wraps the long-form incantations
documented further down — one name per ZPR process, one way to reach each. The long
forms are kept below on purpose: they're the reference when a command misbehaves.

| command | what it does |
|---|---|
| `demo-status` | is every `ph` up? last 10 log lines each. Exit 1 if any is down |
| `demo-check-ph <NAME>` | the same, for one process. Exit 1 when down |
| `demo-watch-ph <NAME>` | `tail -f` its log. `-a` attaches to the tmux session instead |
| `demo-restart-ph <NAME>` | relaunch it, using the config the deploy already placed |
| `demo-stop-ph <NAME>…` | stop one or more, host/container left up. Restart with the above |
| `demo-shell <NAME>` | interactive shell there, in its ZPR working dir |
| `demo-watch-vs` | `tail -f` the **visa service** log (not its adapter) |
| `demo-vs-admin <CMD…>` | `vs-admin` with `--svc-url`, `--ca-cert` and the API key filled in |
| `demo-vs-admin-gui` | alias for `demo-vs-admin gui` |
| `demo-zpr-dashboard` | the `zpr-dashboard` TUI — richer than `demo-vs-admin gui` |
| `demo-zpr-web-dashboard` | local read-only browser monitor for Visa Service state |
| `demo-attr <set\|add\|rm\|del\|show\|push\|save\|selftest>` | edit the attribute file + flush the vs cache |
| `fetch <URL> [curl-args…]` | `curl` under a green SUCCESS / red FAILED banner. Also on `alice` as `~/fetch` |

`<NAME>` is one of:

| NAME | what | where |
|---|---|---|
| `node0` | first substrate node | local Docker `node0` |
| `web0` | OciWeb service adapter | local Docker `web0` |
| `alice` | alice's adapter/client | local Docker `alice` |
| `node1` | substrate node | docker `node1` |
| `vs` | the visa service's **adapter** | docker `vs` |
| `premweb` | web adapter | docker `web1` |

OCI addresses come from `tofu output` at call time — nothing to regenerate after a
`tofu apply`. Override the SSH key with `SSH_KEY=/path`.

Two have a self-check, both offline and needing no infra: `commands/demo-attr selftest`
exercises its jq transforms, and `commands/fetch --selftest` exercises both banners.

`fetch` is the odd one out — no `demo-` prefix, and no `<NAME>`: it takes a URL, and
`deploy-zpr.sh` scp's the same script to `alice`, where `./fetch http://premweb.demo`
is how a policy allow or deny is shown. HTTP 4xx/5xx count as failures; set
`FETCH_TIMEOUT` (default 10s) to bound a denied fetch that would otherwise hang.

**Attributes are tags, not values.** The `.zplc` maps each attribute to a tag
(`prem_user -> #user.prem_user`), so the mere *presence* of the key sets it —
`demo-attr set alice prem_user no` **grants** `prem_user`. `demo-attr del` is the
only way to revoke.

**Build Linux/amd64 demo binaries** from this directory before building the image:

```bash
make ZPR_ROOT=../.. linux-amd64
docker build --platform linux/amd64 -t zpr-multinode .
```

`ZPR_ROOT` must contain the `zpr-core`, `zpr-visaservice`, `zpr-compiler`,
`zpr-utils`, and `zpr-dev-tools` repositories. Rust builds run inside the
Debian dev-env image; the Go dashboard is cross-built with CGO disabled. This
produces ELF binaries usable by the Ubuntu containers and OCI hosts, including
when building from Apple Silicon. The build includes `ph-cli`, which the remote
deploy uses to verify the peer link.

### Isolated source candidate (engineering use only)

`packaging/build-isolated-candidate.py` plans and, only with `--execute`, stages
the required Git repositories under a new candidate directory outside the
source root. Dry-run is the default and performs no writes or Docker calls:

```bash
python3 packaging/build-isolated-candidate.py \
  --source-root ../.. \
  --output-parent /private/tmp \
  --release-id local-review-01
```

Use an existing physical output-parent directory outside the source root;
`/private/tmp` is the macOS example (`/tmp` is a symlink there). On Linux,
an existing non-symlink `/tmp` is suitable.

For a complete content-redacted source report even when safety findings block
execution, add `--preflight-report`. It still returns nonzero on blockers and
cannot be combined with `--execute`. The report includes exact HEAD/tree pins,
submodule identities, approved and unapproved dirty paths, untracked/ignored
exclusions, file hashes, finding locations/categories, missing required inputs,
available tool paths, free disk, and the unique proposed output paths/tags and
command sequence. Proposed paths/tags are not artifacts and are not created or
checked against Docker during dry-run. The report never prints matched private
key contents. The scanner recognizes only bounded Rustdoc header-token lines
without any PEM end marker/payload-shaped line, and an exact shell generator
sequence that combines the fixed X25519 DER prefix with stdin. These references
are recorded in source provenance; source bytes are not rewritten. Other header
uses and all embedded multiline/escaped-inline key blocks remain blocked,
including `#[cfg(test)]` fixtures whose origin is unknown. There is no whole-path
waiver, test-code waiver, or content stripping.

The equivalent read-only Make target is:

```bash
make candidate-preflight ZPR_ROOT=../.. \
  CANDIDATE_OUTPUT_PARENT=/private/tmp CANDIDATE_RELEASE_ID=local-review-01
```

After reviewing the printed source revisions, included-file hashes, exclusions,
Docker tags, and commands, an explicitly authorized local build can use
`--execute`. Tracked worktree changes are staged from `HEAD` unless that exact
`repo:path` is supplied with `--include-dirty`; untracked files are excluded
unless individually supplied with `--include-untracked`. These allowlists are
not recursive. The tool rejects missing repositories/required inputs, unsafe
symlinks, `.local-runtime`, credential/private-key inputs, and cache/build
artifacts before contacting Docker. It also refuses an existing output root or
any existing candidate image tag. Candidate build outputs and source provenance
are isolated from the shared repositories.

The procedure requires a working local Docker daemon and may use Docker base
images, OS package repositories, Rust dependencies, and Go modules. Its
floating builder/toolchain and unpinned base images do not establish byte
reproducibility. It builds local unqualified engineering artifacts only; it
does not load or start the paired images, install them, publish them, or qualify
a host or release. The existing `linux-amd64` Make target remains the direct
shared-worktree build path; use the isolated tool when protecting the shared
source checkout matters.

Source preflight validates the selected snapshot, not arbitrary working-tree
files. An explicitly approved tracked replacement is scanned in place of its
historical HEAD contents; unapproved changes still select and scan HEAD.
Staging writes approved replacements directly, never first writing their old
HEAD bytes. If a provenance diff contains rejected historical material, only
its SHA-256 and a redaction reason are recorded, not its bytes. The selected
replacement must still pass the unchanged scanner; this is not a fixture
exemption. In particular, the selected Makefile must support the unique
`ZPR_BUILDER_IMAGE` tag; an unapproved working-tree fix does not satisfy that
requirement. The required `zpr-pki` runtime helper is a file, not a directory.
Private/cache/artifact exclusions apply inside submodules as well. Allowlists
cannot admit private paths or symlinked inputs, including symlinked parents.
The path-name filter has a narrow exception for the nine required Rust source
modules under Core's vendored `capnp/src/private/` tree; those files still pass
the private-key content scanner. Its `layout_test.rs` sibling is excluded
because the pinned module declares it only under `#[cfg(test)]`, and the
production build does not compile dependency tests.
The tracked `zpr-visaservice/vs/src/bin/vsapikey.rs` and Compiler's
`src/bin/zplc.rs` and `src/bin/zpdump.rs` are likewise admitted as exact Rust
source targets required by the pinned manifests and build/package scripts.
The broader `bin` artifact exclusion remains in force (including the unused
Compiler `zplfmt` target), and these files still pass the private-key content
scanner. Preflight requires all three source entry points.
For a published, immutable snapshot, pass one full commit per repository with
`--revision REPO=FULL_COMMIT`. This mode refuses worktree allowlists and never
reads or stages worktree edits; all selected sources come from `git archive` at
the exact commits. It still requires available Git objects and initialized,
clean submodules at their pinned gitlinks. The report/provenance records the
revision and tree for every repository and each submodule, plus included-file
hashes. This does not replace Cargo's declared Git dependencies with local
sibling repositories; dependency downloads follow the selected
manifests/lockfiles and this is not a hermetic build.

To capture and inspect an immutable source snapshot before starting Docker,
use `--stage-only` with a complete `--revision` set. It writes source files,
`provenance.json`, and an empty artifacts directory under the unique output
root, but makes no Docker calls. After reviewing the staged hashes and
`provenance.json`, `--build-staged CANDIDATE_ROOT` rechecks every staged source
hash and refuses a changed snapshot or nonempty artifacts directory before
checking Docker tags or building. Use the same candidate root for subsequent
build evidence; it is never overwritten.

With separately approved execution, missing tools, nonlocal Docker endpoints,
unavailable Docker, and
existing candidate tags are checked before staging. Approved file hashes and
submodule state are rechecked before output creation. Staging uses pinned Git
commits. Built binaries must have ELF64/amd64 headers; the generated pair is
checked by the existing package verifier without loading images. Successful
execution writes `provenance.json` plus `build-results.json` under the new root,
recording the orchestrator hash, exact local Go and Rust/Cargo versions, built
image IDs and binary/archive hashes. It does not certify those toolchains or
claim byte-reproducible output. A later build failure leaves only the unique candidate
root and any locally built unique tags for explicit review/cleanup; it never
silently deletes or overwrites them.

Tracked submodules must already be initialized, checked out at their parent
gitlink commit, and free of tracked changes, untracked files, and ignored files.
Their paths must match the pinned `.gitmodules` configuration. Nested submodules
are rejected; this tool does not initialize, fetch, or repair any submodule.
Each accepted submodule records its gitlink, observed HEAD, initialization
status, Git tree ID, and included-file hashes in the plan and provenance.
Staging reads its pinned Git snapshot, never arbitrary branch/worktree content,
and rechecks submodule state before creating output. Ordinary file allowlists
cannot override these submodule requirements.

### Paired image-only demo archives (experimental)

The packaging helper can export already-built Linux/amd64 ZPR and Simulator
images into a version-matched pair. It does not build images, include the
runtime configuration or startup scripts, or create an installable demo.
Treat its output as unqualified engineering artifacts; do not use it on a
shared or production host.

From this directory, with Docker available and both image tags already loaded:

```bash
mkdir -p /tmp/zpr-demo-image-pair
python3 packaging/package-demo-images.py build \
  --release-id demo-candidate-20261018-safe-context \
  --output-dir /tmp/zpr-demo-image-pair \
  --zpr-image zpr-multinode:demo-candidate-20261018-safe-context \
  --simulator-image zpr-simulator:demo-candidate-20261018
python3 packaging/package-demo-images.py verify \
  /tmp/zpr-demo-image-pair/zpr-demo-demo-candidate-20261018-safe-context.tar \
  /tmp/zpr-demo-image-pair/simulator-demo-candidate-20261018-safe-context.tar
```

The command creates a SHA-256 sidecar for each archive and refuses to overwrite
existing same-release output files. Compare the sidecars against checksums from
a separately trusted channel; they are not signatures. `install` verifies the
pair before loading either image into Docker, but does not start containers:

```bash
python3 packaging/package-demo-images.py install \
  /path/to/zpr-demo-demo-candidate-20261018-safe-context.tar \
  /path/to/simulator-demo-candidate-20261018-safe-context.tar
```

These example tags identify local candidates, not reproducible releases. The
current ZPR candidate contains pre-existing binaries without a verified source
revision, and the Simulator candidate still requires source-tree bind mounts
at runtime. Runtime-support bundling, target-host setup, lifecycle commands,
and clean Ubuntu acceptance remain incomplete.

#### Published image-import checkpoint

The authenticated [zpr.net download portal](https://zpr.net/#downloads) publishes
the matched outer archives under version `dev-2026-10-18.1`:

| Download | Outer archive SHA-256 |
| --- | --- |
| `zpr-dev-2026-10-18.1-linux-x86_64.tar.gz` | `ef64a73263f5341d27aee0122c472957f57576b05e0dae53ffd5e60d9cdfecce` |
| `simulator-dev-2026-10-18.1-linux-x86_64.tar.gz` | `40f2e07512cc7274ae6634fa92a79cc440fec58e59a45164baf1b22383ad59be` |

These outer archives wrap the image-only pair above, its checksum sidecars,
and README instructions. The ZPR download also includes
`package-demo-images.py`, so verification and image import do not require a
source checkout. These outer checksums differ from those of the inner `.tar`
image packages; compare the correct layer.

On October 18, 2026, the operator reported successful download, extraction,
and loading of both images into Docker on the designated Ubuntu host.
This is operator-reported image-import evidence, not a captured host preflight,
container startup, TUN test, or workload/policy acceptance result. No runtime
start command is provided by this release. Target-generated configuration,
credentials, and a source-independent start/stop/status workflow remain the
next milestone.

#### Runtime-package development checkpoint

The package-owned `packaging/simulator-config.toml` supplies the Simulator's
required `runtime/config.toml`. It contains only `[ui] show_static = true`;
no host credentials, API endpoints, listening overrides, or scenario approvals
are included. An existing selected runtime configuration must match these exact
bytes or assembly refuses it. Candidate preflight requires this configuration
and the Simulator lifecycle, environment, and organization assets before any
build. Earlier r4 archives omitted the ignored Simulator configuration and
cannot start the Simulator; keep those archives immutable and use a corrected
candidate rather than patching an installed r4 release.

The Northstar packaged `policy-demo.zplc` is sourced from the tracked dashboard
example at package time when the runtime directory lacks its copy. If present,
the runtime copy must exactly match the example. Preflight requires and scans
that example source; it never copies an ignored generated worktree artifact.

The v2 packaging helper now adds package-owned runtime assets. Its `install`
command requires `--install-dir` for v2 archives and installs the verified pair
under `<install-dir>/<release-id>/{zpr-demo,simulator}`. This does not upgrade the
published `dev-2026-10-18.1` image-only downloads in place.

For a v2 candidate installed on the disposable Ubuntu host, the ZPR commands
are:

```bash
sudo env ZPR_DEMO_PACKAGE_DIR=/opt/zpr-demo/RELEASE_ID/zpr-demo \
  ZPR_DEMO_STATE_DIR=/var/lib/zpr-demo \
  /opt/zpr-demo/RELEASE_ID/zpr-demo/runtime/zpr-demo-runtime.sh start
```

Replace `RELEASE_ID` and the install root with the actual installed paths.
Use the same environment and root-owned state directory with `status`, `smoke`,
or `stop` instead of `start`. Startup requires root for the demo containers'
TUN and nginx setup; do not initialize state as an ordinary user and then switch
owners. The initializer generates local credentials and compiles policy using
the imported image by immutable ID. Stop preserves identity and Redis state.
`smoke` checks Alice-to-web0 HTTP over ZPR; it is not Simulator scenario
acceptance.

The runtime lifecycle and archive regression tests use stubbed Docker calls.
The real packaged PKI helper has separately generated a CA and an X25519
certificate whose signature and public-key binding verified inside a
network-disabled, unprivileged temporary container. Compose configuration
validation passed without creating containers. None of these checks proves
privileged service startup on Ubuntu. The Simulator runtime remains an
unprovisioned UI bootstrap fixture, not the matching runnable scenario. Do not
advertise the current v2 candidate as a working paired demo before host startup,
workload, and scenario acceptance.

Before using the designated disposable Ubuntu 26.04.1 LTS x86-64 host, install
Docker Engine and Compose v2, then run this read-only host check from the package
source checkout:

```bash
sh packaging/preflight-demo-host.sh
```

It verifies the Ubuntu 26.04 release, x86-64 host and Docker architectures,
local Docker Engine, Compose v2 and accessible `/dev/net/tun`; it reports
detected memory and free disk without imposing unapproved sizing thresholds.
It does not alter host settings, verify that Docker containers can use TUN, or
install/start the demo. Run the focused fixture test on a development host:

```bash
sh packaging/test-preflight-demo-host.sh
```

### Organization runtime lifecycle (local Docker)

Each organization deployment starts a separate phpLDAPadmin directory manager
connected over verified LDAPS to that organization's `directory` container.
Its HTTP listener is published only on host loopback, on a Docker-assigned port
so different organizations do not share a manager or collide on a fixed port.
The manager requires a separate LDAP admin login; it does not prefill or mount
the admin password. The local admin DN is `cn=admin,<directory base DN>`, with
the password stored in the organization's private `directory/ldap-admin-password`.

Deployment registers its browser URL for every trusted-service name targeting
`https://directory:8443` in the rendered Visa configuration. Registration merges
into `.local-runtime/dashboard-stack/provider-managers.json`, preserving other
trusted sources. Set `ZPR_PROVIDER_MANAGER_URLS_FILE` consistently on deployment
and the operator launcher to use a different registry. Control-Service loads
this independent operator configuration at startup, not Simulator profiles or
APIs; restart it after registration. Stopping an organization stops its manager,
but does not affect managers belonging to other sources.

To add or restart only the manager for an already-running organization, without
redeploying LDAP or the Visa Service:

```sh
ZPR_RUNTIME_ROOT=/absolute/path/to/organization/runtime \
ZPR_CONTAINER_PREFIX=great-lakes- ZPR_NETWORK_NAME=zpr-great-lakes \
sh local-compute/start-directory-manager.sh
```

Organization `deploy` and `stop` preserve generated RSA/Noise identities, Visa
API credentials and the active Visa policy database. Redis uses the
organization's `state/redis` bind mount with durable AOF writes. Before replacing
an older, non-persistent Visa container, the launcher exports its database; an
unrecoverable stopped database fails deployment instead of silently restoring
the demo policy. Reconnects use the Packet Handler's fresh-session recovery.
Explicitly approved Visa-only initialization can recover a missing database
using the organization's `fresh-visa-state-approved` marker before activation.
This retains credentials, directory data and editor drafts, but cannot recover
runtime-only policies from the missing database. The marker authorizes
`ZPR_RESTORE_BASE=1` for Visa only and is consumed after the composed policy is
installed. Without explicit approval, the missing-database guard remains active.

First activation installs the composed policy using the deployed keys.
Subsequent activations/redeploys load the persisted policy without `--clear-state`
or an initial-policy override. **Restore base** is the explicit destructive
operation; activation backs up the Visa database alongside policy/directory
state before resetting. Partial or mismatched node identities and incomplete
API credentials fail preflight rather than triggering key rotation.

Changing an organization's compiled policy does not silently replace the active
policy in its persisted Visa database. Review the change, then explicitly install
the compiled artifact through the Visa admin API (`vs-admin policies --path`);
this updates the active policy while retaining the Redis database and identities.

Each organization Compose network uses the `/24` containing the substrate
addresses in its organization profile. All nodes in one profile must share that
subnet, and concurrently running organizations must use non-overlapping ranges.
The legacy `multinode-demo` keeps `172.30.0.0/24`; Great Lakes uses
`172.31.0.0/24` so it can run alongside Load Lab without changing Load Lab's
network or persisted state. Their loopback-published Visa admin APIs also use
separate host ports: `8185` for the legacy/Load Lab deployment and `8186` for
other organization deployments by default. Set `ZPR_VS_ADMIN_PORT` to override
an organization's port when needed.

The installed Linux demo package defaults to `172.30.0.0/24`. When that range
is already in use, set `ZPR_NETWORK_SUBNET` to an unused RFC 1918 IPv4 `/24`
before `zpr-demo-runtime.sh start`; the package derives its fixed host addresses
from that subnet. Docker Compose rejects overlapping Docker networks, but
operators must also check host routes and other networks before selecting it.
The default loopback host ports are Visa admin `8185` and node1 control `5000`;
set `ZPR_VS_ADMIN_PORT` and `ZPR_NODE1_HOST_PORT` to unused ports when a live
demo already owns them.

Organization redeploy also rebuilds the Simulator DNS binding against the
current node0 container and checks service records. Stop removes that binding
before removing its node. DNS zones and TSIG credentials remain organization
scoped. These organization orchestration operations use the Simulator's local
DNS/relay launcher; they do not introduce a Simulator dependency into production
Control Room or Control-Service.

`validate` prepares artifacts in an isolated temporary runtime, never in an
existing organization's live configuration. Run the lifecycle regression tests
from the sibling dashboard checkout:

```sh
go test ./cmd/zpr-web-dashboard -run 'TestOrganization(NodeIdentity|VisaStartup|APICredentials|DNS)'
```

## How to install (OCI hosts)

Brings up three Ubuntu 24.04 instances in OCI — SSH-reachable and able to reach
each other by private IP:

| host        | role                                        | `tun9`                  |
|-------------|---------------------------------------------|-------------------------|
| `node`      | ZPR substrate node (node0), 5000 tcp+udp    | `fd5a:5052:90de::10`    |
| `webserver` | nginx + landing page (`oci-compute/web/`)   | `fd5a:5052:8888::8`     |
| `alice`     | "alice user" workstation, runs an adapter   | none — dynamic ZPR addr |

No ZPR components yet at this stage.

**Prerequisites:** `tofu` + `oci` CLIs installed, `~/.oci/config` set up (profile
`DEFAULT`), and the demo SSH key present at `~/.ssh/zpr-demo(.pub)`.

**Apply:**

```bash
cd oci-compute
tofu init
tofu plan
tofu apply
```

**Get IPs and SSH in:**

```bash
tofu output              # public_ips, private_ips, ssh_commands
ssh -i ~/.ssh/zpr-demo ubuntu@<public_ip>
```

**Verify (per host):**

```bash
ip addr show tun9                       # role's fd5a:... address, state UP (not on alice)
ping <other-host-private-ip>            # inter-host IP works
curl http://<webserver_public_ip>/      # "Hello from OCIWEB" banner + current time
```

**The banner pages are live.** Both web servers run `tools/regen-banner.sh`
continuously, rewriting `/var/www/html/index.html` every 0.2s — so a fetch proves
it reached that host at that moment. On OCI it's `zpr-banner.service` (installed
by cloud-init); in docker it's backgrounded by `local-compute/entrypoint-web1.sh`.
`oci-compute/web/index.html` is now only the boot-time placeholder shown until
the service starts.

To change the banner, edit `tools/regen-banner.sh`, then:

```bash
# OCI — cloud-init only runs at first boot, so push the script yourself:
scp tools/regen-banner.sh ubuntu@<web_ip>:/tmp/ && \
  ssh ubuntu@<web_ip> 'sudo install -m755 /tmp/regen-banner.sh /usr/local/sbin/ \
    && sudo systemctl restart zpr-banner'
# or rebuild just that host:
tofu apply -replace='oci_core_instance.host["webserver"]'

# docker — tools/ is bind-mounted, so no image rebuild needed:
docker compose restart web1
```

**Tear down:** `tofu destroy`.

## How to deploy & run ZPR (OCI hosts)

Once the infra is up, `oci-compute/deploy-zpr.sh` puts the `ph` binary + configs
on all three hosts, injects the node's private IP into the adapter configs, and
starts each `ph` in a detached `tmux` session in the right order. See
[`tf-configure-run-zpr.md`](work/tf-configure-run-zpr.md) for the design.

**Deploy:**

```bash
cd oci-compute
./deploy-zpr.sh              # reads addresses from `tofu output`
```

It's re-runnable: the ~200 MB `ph` upload is skipped when the host already has a
same-size copy, and each `ph` is restarted cleanly (old tmux session killed
first). Re-run after any `tofu apply` that recreated the `node` (its private IP
is what gets injected). Override the SSH key with `SSH_KEY=/path ./deploy-zpr.sh`.

It also writes `premweb.demo` (`fd5a:5052:8888::9`) and `ociweb.demo`
(`fd5a:5052:8888::8`) into the **alice** host's `/etc/hosts`, so
`curl http://ociweb.demo/` works from there once the demo is up.

**Watch a `ph` process** (session name = mode: `node` or `adapter`; Ctrl-b d to
detach):

```bash
ssh -i ~/.ssh/zpr-demo -t ubuntu@<node_public_ip>  tmux attach -t node
ssh -i ~/.ssh/zpr-demo -t ubuntu@<web_public_ip>   tmux attach -t adapter
ssh -i ~/.ssh/zpr-demo -t ubuntu@<alice_public_ip> tmux attach -t adapter
```

**Check state without attaching:**

```bash
ssh -i ~/.ssh/zpr-demo ubuntu@<host> 'tmux ls; pgrep -ax ph'          # sessions + proc
ssh -i ~/.ssh/zpr-demo ubuntu@<host> 'tmux capture-pane -t node -p | tail -20'  # recent log
```

**Restart / stop** a `ph`:

```bash
./deploy-zpr.sh                                                # re-deploy + restart both
ssh -i ~/.ssh/zpr-demo ubuntu@<host> 'tmux kill-session -t node'   # stop one
```

**Layout on each host:** `~/zpr/ph`, the one `*.toml` config for that role, and
an `include/` dir with only the certs/keys that config references. Runtime dir
`/var/run/zpr` is created ubuntu-writable (one `sudo` per host, done by the
script). Note `/var/run` is tmpfs — re-run the script after a host reboot.

**Expected state:** after the local and OCI deployments finish, `node0` and
`node1` each show the other peer at `:5000 (Active)` in `ph-cli link show`.
Only then does `deploy-zpr.sh` start the `web0` and `alice` adapters. Their
links can reach the Visa Service behind `node1` and should proceed past
`Helloing` when policy grants the requested service.

### Full startup sequence (both envs)

Node-to-node links are configured from the authenticated Visa Service topology
and use the reciprocal peer Noise-certificate pins in `node0-conf.toml` and
`node1-conf.toml`. Node1 is behind Docker NAT, so its published substrate
endpoint must be reachable from OCI. Open inbound TCP and UDP port 5000 on the
Docker host and any host firewall.

Set the same externally reachable IPv4 address for both deploy scripts. Do not
use `127.0.0.1`; node0 would connect to itself.

```bash
export NODE1_EXT_ADDR=<public-ip-of-docker-host>
./local-compute/deploy-docker.sh
./oci-compute/deploy-zpr.sh
```

The local script starts `node1`, Visa Service, and the local web adapter. The
OCI script starts `node0`, waits up to 180 seconds for node1's peer link to be
`Active`, then starts `web0` and `alice`. If the wait fails, inspect
`~/zpr/node.log` on node0 and `local-compute/logs/node1.log`; check the peer
certificate pins, `NODE1_EXT_ADDR`, and inbound 5000/TCP+UDP reachability.

### The `alice` host

The hypothetical user alice's workstation (CN `alice`). Its adapter config
[`adapter-alice-conf.toml.template`](zpr-conf/confs/adapter-alice-conf.toml.template)
sets **no** `zpr_addr`/`tun_if` — the address is assigned dynamically by the
visa service, so `ph` creates its own TUN device and therefore runs under
`sudo`. Everything else matches the other hosts: `~/zpr/{ph,adapter-alice-conf.toml,include/}`,
tmux session `adapter`, log tee'd to `~/zpr/adapter.log`.

**SSH in and curl through ZPR** — after the node peer is `Active` and the
adapter has completed authentication:

```bash
ssh -i ~/.ssh/zpr-demo ubuntu@$(tofu -chdir=oci-compute output -json public_ips | jq -r .alice)

curl -v http://[fd5a:5052:8888::8]/     # OciWeb  (webserver in OCI)
curl -v http://[fd5a:5052:8888::9]/     # PremWeb (web1 in the local docker env)
```

Those are the `zpr.addr`s the policy declares for the two services — see
`zpr-conf/admin/multinode-demo.zplc.template`. A curl that hangs or is refused
usually means "no visa", not "no route": check the adapter's output.

Per `zpr-conf/admin/attrfile.json`, `alice` holds `oci_user` but **not**
`prem_user` — so the `OciWeb` curl should succeed and the `PremWeb` one should be
denied. Flip that live by editing the mounted copy and flushing the `attrfile`
service (see the local-docker section below).

**Monitor alice's adapter:**

```bash
A=$(tofu -chdir=oci-compute output -json public_ips | jq -r .alice)

ssh -i ~/.ssh/zpr-demo -t ubuntu@$A tmux attach -t adapter   # live, Ctrl-b d to detach
ssh -i ~/.ssh/zpr-demo ubuntu@$A 'tail -f ~/zpr/adapter.log' # follow the log
ssh -i ~/.ssh/zpr-demo ubuntu@$A 'tmux ls; pgrep -ax ph'     # is it up?
ssh -i ~/.ssh/zpr-demo ubuntu@$A 'ip -br addr'               # the TUN ph created + its ZPR addr
```

Restart it with `./deploy-zpr.sh`, or stop it with `sudo pkill -x ph` (plain
`tmux kill-session` is not enough — `ph` is root here, so tmux running as
`ubuntu` cannot signal it).

If a request stalls, check the adapter's link state and Visa Service policy
decision before assuming the substrate route is missing.



## How to deploy & run ZPR (local docker env)

The local multi-node network runs six containers — `node0`, `node1`, `vs`,
`web0`, `web1`, and `alice` — on the Compose bridge. `node0` hosts the bootstrap
Visa Service adapter and OciWeb; `node1` hosts Alice. The separate PremWeb
adapter can be enabled with `START_PREMWEB_ADAPTER=1`.
Both nodes use static, reciprocal peer entries pinned to the other node's Noise
certificate. This path needs no OCI resources or public host address.

**Build and deploy from Apple Silicon or Linux:**

```bash
make ZPR_ROOT=../.. linux-amd64
docker build --platform linux/amd64 -t zpr-multinode .
./local-compute/deploy-docker.sh
```

The builder creates Linux/amd64 ELF binaries for the Ubuntu containers. Docker
Desktop on Apple Silicon runs the pinned amd64 image under emulation. The
deploy script waits for both `node0` and `node1` to report the peer substrate
endpoint as `(Active)` before starting the endpoint adapters. It is safe to rerun;
configs and policy are regenerated and the managed demo processes restart.

**Native Apple Silicon infrastructure (no x86 emulation):**

```bash
make ZPR_ROOT=../.. linux-arm64
docker build --platform linux/arm64 \
  --build-arg RUNTIME_BASE=debian:trixie-slim \
  --build-arg BIN_DIR=bin/linux-arm64 -t zpr-multinode:arm64 .
export ZPR_MULTINODE_PLATFORM=linux/arm64
export ZPR_MULTINODE_IMAGE=zpr-multinode:arm64
export ZPR_MULTINODE_DIRECTORY_IMAGE=zpr-multinode-directory:arm64
export ZPR_MULTINODE_DIRECTORY_MANAGER_IMAGE=zpr-multinode-directory-manager:arm64
./local-compute/deploy-docker.sh
```

The native builder and runtime both use Debian trixie so the Rust executables,
OpenSSL and system libraries have matching ABIs. ARM64 artifacts have a separate
`bin/linux-arm64` directory; existing amd64 binaries and image tags are retained.
The runtime retains Ubuntu 24.04's Redis 7 package rather than upgrading the
persistent Visa store to Debian trixie's Redis 8 as a side effect.
Nodes, Visa, endpoint adapters, web gateway, directory and directory manager use
the configured platform. The trusted-service helper and machine-control proxy
also match that architecture. Image/platform mismatches fail before deployment
or activation stops the previous runtime.

For dashboard-managed activation, pass these variables into the **Simulator
container environment**, not just the host shell. They must remain configured
for subsequent switches and rollback. An explicitly configured
`ZPR_TRUSTED_SERVICE_BINARY` must likewise point to an ARM64 executable.
Simulator startup can also load these named settings from the operator's
`.local-runtime/dashboard-stack/multinode-platform.json` JSON object, so a
complete container removal/recreation does not discard the architecture choice.
Without these overrides the existing amd64 deployment remains the default.
This does not require changing Control Room or restarting Docker Desktop.

**Watch the ZPR processes** (logs tee'd to a host-mounted volume — no `docker
exec` needed):

```bash
tail -f local-compute/logs/*.log
```

Sessions: `node0` and `node1` (nodes), `vs` and `vs-adapter` (vs container),
`web0-adapter`, and `alice-adapter`; `web1-adapter` is optional. Attach live
(Ctrl-b d to detach):

```bash
docker exec -it vs tmux attach -t vs
```

**Expected state:** `docker exec node0 /app/bin/ph-cli -p
/var/run/zpr/control.sock link show` and the equivalent command for `node1`
both show the other node at `:5000 (Active)`. The `vs` adapter and web0 attach
to node0; Alice attaches to node1. The deploy smoke test requests OciWeb from
Alice across node1 → node0 and fails unless policy-authorized HTTP returns
successfully. Check `local-compute/logs/node0.log` and `node1.log` if the peer
gate times out.

### Dashboard-managed organization directory

Profiles using the `docker-multinode` runtime are activated through the
dashboard's `scripts/activate-organization.sh`, which stops the previous
managed runtime before starting the selected organization's Compose project.
The organization profile's LDIF seeds a private LDAPS sidecar and the existing
mTLS trusted-service provider. Directory data, passwords, and TLS keys live
under `.local-runtime/multinode/<organization-id>/directory`; the shared
architecture-matched provider binary lives under `.local-runtime/dashboard-stack/`.
The directory service is attached only to that organization's private Compose
network and publishes no host port. The generic `multinode-demo` deployment
does not enable the directory sidecar.

Organization runtime nodes may specify optional `latitude` and `longitude`
together, within `[-90,90]` and `[-180,180]`. Deployment renders them into the
Visa Service's `[nodes."node0.demo"]` configuration, matching the generated node
CNs by index. Bundled organizations provide approximate simulation coordinates;
`coordinate_note` records each guess or city-center approximation, not a real
company address. Control Room receives coordinates through the Visa Service
Admin API, never by reading Simulator profiles. Re-deploy to update an existing
runtime; changing a seed profile alone does not change a running service.

Use the deployer's `validate` action to seed the selected organization's private
directory and test LDAPS plus mTLS device-owner and user-role lookups without
starting or stopping a ZPR Compose runtime. For multi-node profiles it also
renders and compiles the policy artifacts:

```bash
ZPR_ORGANIZATION_ID=redwood \
ZPR_RUNTIME_ROOT=../../.local-runtime/multinode/redwood \
  ./local-compute/deploy-docker.sh validate
```

This exposes organization identities and attributes to Visa Service through
trusted-service mappings and to the dashboard's LDAP-backed views. The
multi-node demo's compiled policy still governs generic OciWeb/PremWeb
endpoints; it does not yet enforce Redwood's sample role rules. Redwood's
RouteExchange, FleetTelemetry, and ShipmentLedger entries remain illustrative
and are not deployed services.

**Operator client (`bob`):** `deploy-docker.sh` renders the host-side client adapter and
generates its key at `local-compute/bob/` (`adapter-bob-conf.toml` +
`client.key`) — run `sudo bin/ph adapter -c adapter-bob-conf.toml` from there
to reach the ZPR web services.

**Administer the visa service (`vs-admin` GUI):** the vsapi access key that
`vs-admin` needs is the same `client.key` generated each deploy at
`local-compute/bob/client.key` (host side). `vs-admin` is baked into the image,
so launch it from a terminal attached to the `vs` container, passing the key via
`VS_API_KEY` (no need to copy the file in). The admin API listens on the vs ZPR
address `[fd5a:5052::1]:8182` and presents a self-signed TLS cert, so `--ca-cert`
points at that same cert:

```bash
docker exec -e VS_API_KEY="$(cat local-compute/bob/client.key)" -it vs \
  /app/bin/vs-admin \
    --svc-url "https://[fd5a:5052::1]:8182" \
    --ca-cert /conf/include/admin-tls-cert.pem \
    gui
```

Drop `gui` for one-shot commands (e.g. `services`, `policies`, `actors`, `visas`).
`commands/demo-vs-admin` wraps all of this — `commands/demo-vs-admin-gui`, or
`commands/demo-vs-admin actors`.

For watching the service, prefer `commands/demo-zpr-dashboard`: the `zpr-dashboard`
TUI (built from `zpr-visaservice/zpr-dashboard`) is a richer view of the same admin
API. It also runs inside `vs`, with cwd `/conf` — it has no flags and reads
`./config.toml`, which `deploy-docker.sh` installs there from
`zpr-conf/confs/zpr-dashboard-config.toml`. The API key goes in as `ZPR_API_KEY`,
which overrides the file.

**Web monitor:** after `local-compute/deploy-docker.sh`, run
`commands/demo-zpr-web-dashboard` and open `http://127.0.0.1:8788`. The deploy
script creates a separate read-only API key for the monitor. The `vs` container
relays its admin TLS port to host loopback at `127.0.0.1:8183`; the relay is not
published to the LAN, and the browser never receives the API key.

If the Docker image predates the admin relay, rebuild it with
`docker build -t zpr-multinode .` before re-running `local-compute/deploy-docker.sh`.

**Editing the attribute file (`attrfile.json`) live:** `zpr-conf/admin/attrfile.json`
holds the JSON attributes referenced by the policy and read by the visa service.
`deploy-docker.sh` copies it to `local-compute/conf/vs/attrfile.json`, which is
bind-mounted into the `vs` container at `/conf/attrfile.json` (same dir as
`vs_keys.toml`). To change attributes mid-demo, edit the mounted copy on the host
and tell the visa service to reload it:

```bash
$EDITOR local-compute/conf/vs/attrfile.json          # live copy, no restart needed

docker exec -e VS_API_KEY="$(cat local-compute/bob/client.key)" -it vs \
  /app/bin/vs-admin \
    --svc-url "https://[fd5a:5052::1]:8182" \
    --ca-cert /conf/include/admin-tls-cert.pem \
    services -i attrfile --flush
```

`local-compute/conf/` is regenerated on every deploy, so copy the edit back into
`zpr-conf/admin/attrfile.json` to keep it.

`commands/demo-attr` does all of the above in one step — edit, flush, and
`demo-attr save` for the copy-back:

```bash
commands/demo-attr show                        # the live file
commands/demo-attr del alice oci_user     # edit + flush
commands/demo-attr save                        # keep it across the next deploy
commands/demo-attr push                        # or throw it away, back to the baseline
```

**Updating the policy** (edited `zpr-conf/admin/multinode-demo.zpl` or
`multinode-demo.zplc.template`): just re-run `./local-compute/deploy-docker.sh`.
It recompiles the policy to `multinode-demo.bin2` and restarts `vs` with
`--clear-state`, which loads the new policy. No image rebuild needed. (The
containers, tun9, and valkey stay up; only the ZPR processes are relaunched.)

**Updating a binary** (new `ph`/`vs`/etc. in `bin/`): binaries are **baked into
the image**, not mounted, so rebuild the image first, then re-deploy:

```bash
docker build -t zpr-multinode .        # picks up the new bin/
./local-compute/deploy-docker.sh       # `up -d` recreates containers on the new image, relaunches ZPR
```

**Teardown:** `docker compose down`.
## Runtime startup recovery

### Local operator UI bootstrap

`packaging/runtime/start-operator-ui.sh` starts independent Control-Service and
Control Room containers from the pinned installed ZPR image on a Linux host.
Set `DOCKER_HOST` to the daemon holding the ZPR stack, `ZPR_OPERATOR_IMAGE` to
its immutable image ID, `ZPR_VS_CONTAINER` to the running Visa container,
`ZPR_VS_MONITOR_KEY_FILE` to the absolute installed `bob/web-monitor.key` path,
and `ZPR_OPERATOR_STATE_DIR` to a new private absolute directory.

The script generates a separate 30-day operator CA and server/client credentials
on the target host. It copies only the existing read-only Visa monitor API key
and public admin trust certificate; Visa identities and policy are unchanged.
Control-Service uses mTLS on `127.0.0.1:8790`, and Control Room uses the existing
local-only mode at `http://127.0.0.1:8787`. Containers use host networking so these
listeners remain loopback-only, without Docker-socket or Simulator mounts.
Credentials persist in the private state directory. The launcher accepts
`start`, `stop`, and `status`, reuses matching labeled containers, and refuses to
alter unrelated containers or rotate partial credentials. Start waits for a
connected Visa snapshot before reporting readiness.

On workbench, both services survived Docker restart, the UI returned a connected
snapshot of five actors and the live two-node peer link with Simulator stopped,
and Control-Service rejected a request without a client certificate.
Alice-to-web0 HTTP remained healthy during the independence test.

Policy-Service now runs separately with mTLS at `127.0.0.1:8789`, using a private
SQLite repository under `policy-store` in the operator state directory. It
supports draft creation and revision editing through Control Room. Target-host
checks passed for revision persistence after operator stop/start and HTTP 409
on stale edits, with Simulator stopped and active policy unchanged. The launcher
manages all three operator services and upgrades only its verified managed
Control-Service when adding the Policy-Service connection.

Compiler validation uses the packaged `zplc` with a read-only configuration and
public-key snapshot under `policy-compiler` in operator state. No private identity
keys or live apply credentials are mounted. `test-operator-policy.sh` exercises
valid and invalid source through Control Room without saving or applying it.
Target-host checks returned HTTP 200 for valid source and HTTP 422 with line/column
diagnostics for invalid source. Compiler warnings are preserved, including the
current fixture's missing trusted-service certificate and admin policy warnings.
Upgrading the verified managed Policy-Service preserves the draft database.

This is not the full production operator deployment:
live policy apply, enrollment, named-user login and telemetry are not configured, and the UI is not
remotely exposed. Certificate renewal is operator-managed. To access it from
another workstation, keep it loopback-only and use an SSH tunnel:

```sh
ssh -N -L 8787:127.0.0.1:8787 dubnom@workbench.local
```

Then open `http://127.0.0.1:8787` on that workstation. The published installer
embeds this launcher through `operator-start`, `operator-status`, and
`operator-stop`, with private root-owned state at `/var/lib/zpr-demo-state/operator`.
The earlier user-owned workbench setup remains separate; the installer refuses
to adopt its containers automatically. Future runtime package builds include
the standalone launcher alongside the other runtime scripts.

### Ubuntu target-host checks (2026-10-18)

On the disposable Linux x86-64 workbench, actual Alice-to-web0 HTTP succeeded
across both nodes. A full six-container stop/start retained the shared identity
and compiled-policy fingerprints plus the stored `policy:current` value; HTTP
recovered after relaunching the application sessions against persisted policy.
This check used the Docker CLI directly, not the installer's root wrapper.
The downloaded archive pair also passed checksum validation and a package-helper
installation into a fresh, separate directory without starting a second stack.

The separate Simulator package served its organization UI on loopback port 8788
and survived stop/start. Alice-to-web0 HTTP still passed with Simulator stopped.
The original fixture remains unprovisioned. The separate scenario add-on now
verifies real allowed HTTP and explicit Visa policy denial without provisioning
those fixture machines.
Control Room initially refused startup without independent Control-Service
configuration and mTLS credentials. The local read-only bootstrap above now
passes live topology and independence checks. Persistent policy draft editing,
compiler validation and stale-edit rejection are verified; live apply is not
configured. Full fresh-host installer startup,
host reboot recovery, and production qualification remain unverified.

On 2026-10-19 UTC the root installer also passed a clean-state installation from
the three downloaded archives on the existing workbench host, followed by a full
network/operator/Simulator stop/start. Fresh identities, Redis, operator mTLS,
draft database and Simulator state were generated; none of the old state was
reused. A saved revision-2 draft persisted, stale edits returned HTTP 409, and
identity/configuration fingerprints plus the active policy remained unchanged.
Prior installation/state and stopped operator/Simulator containers were retained
under timestamped `before-clean` names.

`packaging/runtime/test-clean-installed-workflow.sh` repeats that destructive
runtime acceptance on the designated workbench only, with explicit root and
`--disposable-host` acknowledgment. It is not a general reset tool. The test ran
inside a temporary root tooling container sharing the real Ubuntu host Docker,
TUN, OS metadata and package/state paths; it does not qualify a clean OS or reboot.

Clean-state testing caught a startup transition where bootstrap peer links
initially worked but briefly dropped as Visa reconciled node configuration.
The runtime now waits for both named nodes to be synchronized with no pending
policy installs/revocations, both peer links to be Active and actual Alice HTTP
to pass for six consecutive samples. Failure resets the sample sequence and
exhaustion fails explicitly. This startup gate handles observed convergence;
it is not a claim that the Packet Handler reconfiguration behavior was fixed.

The runtime prepares private empty `conf/<service>/include` directories before
mounting shared identities beneath read-only `/conf` mounts. Existing identities
are preserved. A pending policy bootstrap can be retried automatically only when
all six prior containers remain in Docker's `created` state and Redis contains
only the matching pending marker. If any container may have run or Redis contains
other state, startup stops for operator inspection instead of resetting policy.
For the published `demo-runtime-20261018-1631` packages, download the updated
`zpr-cli` from the website and retry `start --disposable-host`; its
hash-pinned runtime update applies these fixes without reinstalling archives
or replacing generated identities.
The banner generator sets its own `022` umask for public web content; it must
not inherit the private `077` identity/logging umask. The updated fail-fast
web entrypoints cause Compose to recreate web0/web1 on the next start so
the banner fix is loaded, without resetting Redis or identity state.
Initializer reruns distinguish mutable Redis/log files from immutable identity
files. Empty runtime files and service-created read permissions are accepted
under private roots; owner, link, and write-access checks remain enforced.
Identity/configuration files and policy markers still require mode `0600`.
Smoke makes three bounded direct HTTP attempts, then prints IPv6 routes,
addresses, node links, and runtime log tails on failure. This helps distinguish
authorization, routing and forwarding faults without resetting policy.

#### Operator acceptance checklist: established two-machine flow

The checked items below record the existing workbench evidence above; this
checklist was not run as part of this documentation change. It is not a
production qualification or a substitute for the explicit host checks below.

- [x] **Prerequisites and package identity — existing workbench evidence.**
  Use the matching ZPR, Simulator, and scenario-admission packages; verify the
  archive checksums before installation. The runtime requires an isolated
  Linux/amd64 disposable demo host, Docker Compose v2, the locally imported
  package image, and root for the TUN and container setup. Keep the installed
  package separate from its private persistent state directory. Do not copy
  generated identities between hosts.
- [x] **Identity and policy persistence — existing workbench evidence.**
  A clean-state install generated fresh identities and state. Across the
  subsequent full stop/start, the identity/configuration fingerprint, compiled
  policy fingerprint, saved policy marker, and active `policy:current` value
  were unchanged. Record only whether the before/after fingerprints match;
  never copy identity files, private keys, credentials, or raw policy state into
  an acceptance report.
- [x] **Ordered start and protected HTTP — existing workbench evidence.**
  The installed-package sequence was ZPR `start --disposable-host`, `smoke`,
  `operator-start`, and Simulator `simulator-start --disposable-host` followed
  by `simulator-test`. Startup waits for both named nodes to synchronize, both
  peer links to be Active, and Alice-to-web0 HTTP to pass six consecutive
  readiness samples. `smoke` checks the allowed Alice-to-web0 path; the
  scenario add-on checks real allowed HTTP and an explicit Visa policy denial.
  A test passes only when the package command exits successfully and the
  scenario reports its expected authorization outcomes; an arbitrary network
  failure is not evidence of a policy denial.
- [x] **Stop/start recovery — existing workbench evidence.**
  The recorded order was `simulator-stop`, `operator-stop`, then ZPR `stop`;
  recovery used ZPR `start --disposable-host`, `smoke`, `operator-start`,
  Simulator `simulator-start --disposable-host`, and `simulator-test`. The
  allowed path recovered against persisted policy and the authorization
  scenario passed again. Normal `stop` retains identity, policy, Redis, and log
  state; it is not a state reset.
- [ ] **Fresh-host, reboot, and rollback qualification — unverified.**
  The clean-state test ran on the existing workbench host, not a fresh OS.
  Host reboot recovery and restoration from a retained `before-clean` backup
  have not been tested. Do not count a container stop/start as a host reboot.
  Schedule these only with operator approval, root access, a disposable host,
  and console/rollback access.

For a future authorized run, the packaged workflow exercised by
`packaging/runtime/test-clean-installed-workflow.sh` uses the following
commands. They are documented here as an operator procedure only; they were
not executed for this change. In that script, `installer` is the verified
`zpr-cli` in the absolute downloads directory:

```sh
bash "$installer" install "$downloads"
bash "$installer" start --disposable-host
bash "$installer" smoke
bash "$installer" operator-start
bash "$installer" simulator-install "$downloads/simulator-scenario-admission-20261019-r6.tar"
bash "$installer" simulator-start --disposable-host
bash "$installer" simulator-test
bash "$installer" simulator-stop
bash "$installer" operator-stop
bash "$installer" stop
bash "$installer" start --disposable-host
bash "$installer" smoke
bash "$installer" operator-start
bash "$installer" simulator-start --disposable-host
bash "$installer" simulator-test
bash "$installer" status
bash "$installer" operator-status
bash "$installer" simulator-status
```

The clean-state helper is destructive to the active installation and is not a
routine restart command. It requires root, an absolute non-symlink downloads
directory, and the explicit `--disposable-host` acknowledgement. Before
changing anything it checks the expected container images and labels; it
retains prior state and managed containers under timestamped `before-clean`
names. Its failure path preserves new and prior state for inspection; it does
not provide an automatic rollback.

**Abort gates:** stop and preserve all state if checksum/package identity
validation fails, an unexpected container or image is found, startup reports a
pending or unsafe policy-bootstrap state, either peer link fails to become
Active, the allowed HTTP check fails, or the scenario's expected Visa denial is
not observed. Do not delete state, clear Redis, remove a pending marker, or
repeat the clean-state helper to force progress; inspect the retained state
and logs with the designated operator first.

**Evidence to retain:** UTC time, host role and disposable-host acknowledgement,
package release and checksum result, command names and exit statuses, status
and readiness outcomes, whether identity/policy fingerprints match, and
redacted log excerpts needed to distinguish routing from authorization.
Exclude keys, certificates, API credentials, full configurations, and raw
identity or policy contents. Record fresh-host, reboot, and rollback as
**UNVERIFIED** until each is separately authorized, run, and reviewed.
