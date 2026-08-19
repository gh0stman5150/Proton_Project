# Runbook: changing the qBittorrent fleet without drift

## Purpose

This runbook enforces the operational meaning of **change one, change all** for the five managed qBittorrent services. It prevents a repair made for Sonarr or Prowlarr from becoming a private fork that leaves Lidarr, Radarr, or Whisparr on different behavior.

The rule applies to shared configuration and code. It does not collapse the independent Proton failure domains.

## Availability, storage, and boot contract

- Keep uploading and seeding enabled. Do not globally pause torrents or introduce queueing, active-upload limits, or seeding limits to simplify a rollout.
- Reconcile shared changes sequentially. The four untouched clients remain available while one client is recreated and health-gated; stop on the first failure.
- The active shared `/mnt/data` policy is SMB 3.1.1 with `cache=none`. Treat any mount-option or incomplete-storage change as Class 2 and apply it fleet-wide; do not create a Sonarr-only storage fork.
- Local incomplete storage is not capacity-safe on the current host. Do not document or deploy it as the current mitigation without additional fleet capacity and a complete migration design.
- Both NAS mount units require and follow the route-and-TCP-445 readiness gate. Docker wants and follows all five Proton WireGuard units. Changes to either dependency graph belong in the installer and require reboot-path validation.
- `cache=none` is containment, not proof of a kernel repair. A kernel candidate requires exact patch provenance, a rollback kernel, and controlled all-five storage and runtime validation.

## Fleet definition

The canonical catalog is `qbittorrent-instances.tsv`, installed as `/opt/qbittorrent-common/qbittorrent-instances.tsv`.

| Instance | Container | Web UI | Tunnel bind | Interface | Legacy port reference |
| --- | --- | ---: | --- | --- | ---: |
| Lidarr | `qbittorrent-lidarr` | 8081 | 10.2.0.2 | `pvlidarr` | 51058 |
| Prowlarr | `qbittorrent-prowlarr` | 8082 | 10.6.0.2 | `pvprowlarr` | 51057 |
| Radarr | `qbittorrent-radarr` | 8083 | 10.3.0.2 | `pvradarr` | 51056 |
| Sonarr | `qbittorrent-sonarr` | 8084 | 10.4.0.2 | `pvsonarr` | 51055 |
| Whisparr | `qbittorrent-whisparr` | 8085 | 10.5.0.2 | `pvwhisparr` | 51054 |

The legacy values are retained only for incident/history comparison. They do not make Compose render and are never valid lease inputs. Every wrapper requires the synchronizer to inject a current `QBT_PUBLISHED_PORT` and requires its tunnel bind IP; neither has a permissive fallback.

## Change classification

Classify a proposed change before editing files.

### Class 1: dynamic per-instance event

Examples:

- Proton gives Sonarr a new NAT-PMP port;
- one tunnel reconnects;
- one instance selects another Proton endpoint;
- one instance's container IP changes;
- one instance is intentionally stopped or resumed.

Required behavior:

- mutate only that instance's runtime state and one-key port artifact;
- recreate only its matching qBittorrent service when the published mapping changes;
- leave the other four leases and containers alone;
- use the same common synchronizer and validation logic used by every instance.

A Sonarr port must never be copied to Prowlarr, Radarr, Lidarr, or Whisparr. “Change one, change all” means the automation handles the same event identically, not that independent runtime values become identical.

### Class 2: shared fleet behavior or structure

Examples:

- container image/tag;
- health check;
- stop grace period or s6 shutdown timing;
- UID/GID/umask/timezone;
- restart policy;
- common volume or network policy;
- init hook;
- port-sync, route, kill-switch, allocator, or watcher code;
- common qBittorrent preference;
- a security hardening control;
- a storage-layout mitigation such as local incomplete directories.
- shared CIFS mount options or NAS/Docker boot dependencies.

Required behavior:

- implement the change at the shared source, not in one wrapper;
- render/validate all five projects;
- deploy one version of the code/configuration;
- roll every affected instance sequentially and health-gate each one;
- finish the complete fleet or roll changed members back;
- run full fleet acceptance.

### Class 3: intentional instance identity or role override

Examples:

- Web UI port;
- bind IP and interface;
- WireGuard address subnet, table, and rule priority;
- Compose project/service/container name;
- config/download paths and role-specific category names;
- credentials;
- a documented workload-specific qBittorrent preference.

Required behavior:

- express identity in the manifest or protected per-instance environment;
- document a role preference as an explicit override;
- keep the surrounding structure common;
- update table-driven tests if identity metadata changes;
- verify all five so a legitimate override does not conceal accidental drift.

## Sources of truth

### Shared Compose policy

Repository:

```text
qbittorrent-compose.common.yml
```

Installed:

```text
/opt/qbittorrent-common/docker-compose.common.yml
```

Every `/opt/qbittorrent-<instance>/docker-compose.yml` is a thin wrapper that extends `qbittorrent-common`. Do not duplicate `image`, `restart`, `stop_grace_period`, `healthcheck`, or other fleet policy into an instance wrapper.

### Instance manifest

Repository:

```text
qbittorrent-instances.tsv
```

Installed:

```text
/opt/qbittorrent-common/qbittorrent-instances.tsv
```

The installer and verifier consume this table. Do not add a new instance by copying a case statement into several scripts.

### Static Compose environment

Each `/opt/qbittorrent-<instance>/.env` must contain exactly one assignment:

```dotenv
QBT_HOST_BIND_IP=<that-instance-tunnel-address>
```

Comments and blank lines are allowed. A dynamic port is not.

### Dynamic port artifact

Each `/etc/proton/instances/<instance>/qbittorrent-port.env` must contain exactly one assignment:

```dotenv
QBT_PUBLISHED_PORT=<that-instance-active-applied-port>
```

`QBT_FORWARDED_PORT` is obsolete. The artifact is atomically replaced by the synchronizer and is never the Compose project's `.env`.

### Runtime lease

Each `/run/proton/<instance>/proton-port.state` stores the live NAT-PMP result. Runtime state is volatile and authoritative only after the current tunnel successfully obtains a lease. Never use a pre-reboot persistent artifact as proof of a post-reboot lease.

## Standard change workflow

### 1. State the invariant and blast radius

Before editing, record:

- change class;
- shared files affected;
- allowed instance-specific fields;
- whether containers must be recreated;
- whether Proton units must restart;
- rollback version/files;
- expected health and port-parity gates.

If a change starts as an instance-local fix but affects behavior common to all qBittorrent clients, reclassify it as Class 2 before implementation.

### 2. Capture a non-secret baseline

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only &&
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config &&
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

Capture container image IDs and health without printing credentials:

```bash
for instance in lidarr prowlarr radarr sonarr whisparr; do
  docker inspect "qbittorrent-${instance}" --format \
    '{{.Name}} image={{.Image}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} started={{.State.StartedAt}}'
done
```

If runtime verification fails before the change, stop and diagnose. A rolling structural deployment must not begin on top of an unhealthy, zombie, or persistently `D`-state member.

### 3. Back up mutable state

Back up only the explicit files required for rollback. At minimum, retain:

- the five wrapper Compose files;
- the installed shared Compose file and manifest;
- protected per-instance `.env` files without exposing them in logs;
- qBittorrent configuration files;
- the installed scripts and systemd units being replaced.

Use an operator-controlled directory with restrictive permissions. Do not commit credentials, cookies, WireGuard private keys, or live protected environment files to Git.

### 4. Make the change at the correct layer

For shared Compose behavior, edit only:

```text
qbittorrent-compose.common.yml
```

For identity metadata, edit:

```text
qbittorrent-instances.tsv
```

For shared orchestration behavior, edit the canonical common script/unit and its tests. Do not create `*-sonarr.sh` or a private block conditioned on one existing instance unless the difference is a documented identity/role override.

For qBittorrent preferences, do not copy entire `qBittorrent.conf` files across instances. They contain ports, paths, categories, credentials/cookies, and role state. Maintain an allowlist of fleet-controlled keys plus a documented override map.

### 5. Run repository validation

From the repository root:

```bash
bash -n ./*.sh tools/*.sh
./bats-core/bin/bats tests/*.bats
git diff --check
```

If `shfmt` and `shellcheck` are installed:

```bash
shfmt -d ./*.sh tools/*.sh tests/*.bats
shellcheck ./*.sh tools/*.sh
```

Tests for a shared fix must be table-driven over all five instances or exercise the shared implementation directly. A grep that happens to find another instance's value is not an adequate per-instance assertion.

Required concurrency coverage for route/kill-switch changes includes:

- five simultaneous instance starts;
- a stateful mock that returns `EEXIST` for duplicate rule insertion;
- proof that only one shared mutation critical section runs at a time;
- idempotent repeated reconciliation;
- concurrent up/down preserving the other instances' rules;
- lock timeout before any mutation;
- watcher timeout logging/skipping without process exit;
- separate per-instance state directories sharing one global kill-switch lock.

### 6. Stage installed common configuration

The installer deploys:

```text
qbittorrent-compose.common.yml
  -> /opt/qbittorrent-common/docker-compose.common.yml

qbittorrent-instances.tsv
  -> /opt/qbittorrent-common/qbittorrent-instances.tsv

tools/verify-qbittorrent-fleet.sh
  -> /usr/local/bin/proton/proton-qbt-fleet-verify.sh

tools/reconcile-qbittorrent-fleet.sh
  -> /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh
```

Systemd `ExecStart` paths must point into `/usr/local/bin/proton`, never the source checkout. Installed script targets must be root-owned and executable.

During installation, every existing `/etc/proton/instances/<instance>/qbittorrent-port.env` is validated and atomically canonicalized to one `QBT_PUBLISHED_PORT` assignment. Its numeric value is preserved; the obsolete alias is removed.

The installer also reconciles manifest-owned `VPN_TABLE` and `QBT_VPN_RULE_PRIORITY` in each existing `proton.env`, plus `QBT_INSTANCE_NAME` in each existing `qbittorrent.env`. It updates only those non-secret keys, removes duplicate assignments for them, and preserves credentials, WireGuard material, and unrelated settings.

Deploying files does not itself prove that long-running services use the new behavior. Restart/reconcile affected units explicitly after preflight.

### 7. Protected preflight before the first recreation

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --preflight
```

The command checks all five before any mutation. Resolve every failure. Do not bypass it by recreating instances manually.

### 8. Roll out shared container/config changes

For a shared Compose, image, init, or fleet-controlled qBittorrent change:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The reconciler:

1. validates protected configuration;
2. refuses before the first change if any instance is absent, unhealthy, zombie, or has a persistent `D`-state task across multiple samples;
3. reads each instance's own live Proton state;
4. forces the common synchronizer to wait for its per-instance lock and recreate one instance at a time;
5. waits for health before advancing;
6. stops on first failure;
7. runs full runtime verification after the fifth member.

The recreate command is the acceptance gate; it already runs final runtime verification. When combining it with installation or other prerequisites, join commands with `&&` so a later command cannot mask a failed rollout exit status.

A canary is allowed as an observation step only if the change plan explicitly requires it. A successful canary is not completion. Continue the same version through the other four or restore the canary to the fleet baseline.

### 9. Roll out shared Proton/systemd code

After deploying route, kill-switch, watcher, port-forward, allocator, or sync code:

1. run `systemctl daemon-reload` if units changed;
2. verify all `ExecStart` targets and modes;
3. restart affected instance chains sequentially;
4. keep route and kill-switch locks globally shared;
5. verify each service before advancing;
6. run the full fleet runtime gate.

Example service inspection:

```bash
for instance in lidarr prowlarr radarr sonarr whisparr; do
  systemctl status \
    "proton-wg@${instance}.service" \
    "proton-port-forward@${instance}.service" \
    "proton-docker-watch@${instance}.service" \
    "proton-healthcheck@${instance}.service" \
    --no-pager -l
done
```

Do not restart all WireGuard instances concurrently during a high-risk incident recovery merely to prove the lock. Concurrency belongs in automated tests; sequential production rollout gives better containment.

### 10. Final acceptance

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

For every instance, require:

- container status `running` and health `healthy`;
- current Proton lease equals the one-key persistent artifact;
- artifact equals `TORRENTING_PORT`;
- TCP and UDP mappings both equal that port;
- mappings bind only to the instance's VPN address;
- qBittorrent's configured/listening port equals that port;
- its source `/32` selects the matching VPN table;
- no duplicate shared policy rules;
- no direct torrent binding on `0.0.0.0`;
- no new kernel/CIFS, route, Docker lifecycle, or systemd execution errors.
- existing uploads and seeding resume without a new active-upload, seeding, or queueing limit.

Record the deployed revision and validation time.

## Dynamic Proton port workflow

A normal lease change must use the per-instance automation:

```text
proton-port-forward@<instance>
  -> /run/proton/<instance>/proton-port.state
  -> proton-qbittorrent-sync-safe.sh <instance>
  -> qB API + one-key artifact + matching Compose service
  -> TCP/UDP/API verification
```

Manual trigger:

```bash
sudo systemctl start proton-qbt-allocate@prowlarr.service
```

Expected result: only `qbittorrent-prowlarr` may be recreated. A new Prowlarr lease is not a reason to recreate the other four because they retain different valid leases. Fleet consistency is proved by the common implementation and the final verifier, not by synchronized restart timestamps.

## qBittorrent preference governance

Current configuration files contain a mixture of shared behavior, role settings, and generated/runtime values. Examples of observed drift include Sonarr connection/file-pool/request-queue values, a Radarr tracker URL, Lidarr excluded-file filtering, and differing AutoRun behavior.

Classify keys before normalization:

### Fleet-controlled candidates

- connection limits and queue safety defaults;
- disk cache/file pool policy;
- request queue bounds;
- UPnP/NAT-PMP client behavior where Proton port forwarding owns the port;
- anonymous mode and privacy controls;
- common Web UI/session security controls;
- incomplete-storage strategy;
- common tracker policy if intentionally centralized.

### Required per-instance values

- Web UI port;
- torrent listen port (runtime-managed);
- download/save/incomplete paths if role-specific;
- categories/tags and automatic-management paths;
- credentials, cookies, certificates, and API/session secrets;
- AutoRun command where a workload intentionally needs it.

### Normalization process

1. Export only key names and sanitized values for comparison.
2. Define a fleet allowlist and explicit override table.
3. Back up all five configs.
4. Stop or use the qBittorrent API as required for safe persistence.
5. Apply the same fleet-controlled value to all five.
6. Reapply documented role overrides.
7. restart/reconcile all five sequentially if necessary;
8. verify API values and full port parity.

Do not use one instance's entire config file as a template. A stale nested Lidarr config was observed under `config/qBittorrent/config/`; confirm whether such files are inactive before archiving them, and never delete them as part of an unrelated fleet change.

## Rollback

Trigger rollback when:

- the first recreated instance fails health;
- port parity fails;
- routing or kill-switch verification fails;
- the new image/config cannot read existing state;
- CIFS or kernel errors appear;
- behavior differs unexpectedly between instances.

Rollback sequence:

1. Stop the rollout before changing the next instance.
2. Preserve failure evidence.
3. Restore the previous shared source/installed file and affected script/unit versions.
4. run `systemctl daemon-reload` if units were restored;
5. recreate every already-changed member with its own current Proton lease;
6. verify restored members and untouched members together;
7. if safe rollback cannot be completed, stop the affected automation and escalate rather than improvising a one-instance configuration.

The fleet is not in a valid steady state while some members intentionally run the old shared policy and others the new one.

## Pull-request/change-record checklist

- [ ] Change classified as dynamic, shared, or intentional override.
- [ ] Shared change implemented once in common source.
- [ ] Manifest updated for every identity change.
- [ ] No dynamic port added to a project `.env`.
- [ ] Port artifact contains only `QBT_PUBLISHED_PORT`.
- [ ] No systemd unit executes from `proton_project`.
- [ ] All executable targets are installed mode `0755`.
- [ ] All five wrappers resolve through Docker Compose.
- [ ] Static fleet verifier passes.
- [ ] Protected configuration verifier passes.
- [ ] Automated tests, syntax checks, and diff checks pass.
- [ ] Concurrency test added for shared global state changes.
- [ ] Pre-existing unhealthy/zombie/persistent-`D`-state member resolved before rollout.
- [ ] Shared change rolled sequentially through all five or fully rolled back.
- [ ] Each instance retained its own live Proton port.
- [ ] Final runtime fleet verifier passes.
- [ ] Kernel, Docker, Proton, and health journals reviewed.
- [ ] Documentation and rollback record updated.

## Related documents

- `docs/architecture/qbittorrent-fleet-contract.md`
- `docs/runbooks/qbittorrent-port-sync.md`
- `docs/runbooks/qbittorrent-wedge-recovery.md`
- `docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md`
