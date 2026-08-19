# qBittorrent fleet architecture and invariants

## Purpose

This document defines what must be identical across the five managed qBittorrent instances, what must remain instance-specific, and how Proton's dynamic port is applied without allowing configuration drift.

The fleet consists of:

- `qbittorrent-lidarr`
- `qbittorrent-prowlarr`
- `qbittorrent-radarr`
- `qbittorrent-sonarr`
- `qbittorrent-whisparr`

The phrase **change one, change all** applies to fleet-controlled structure and behavior. It does not mean that all five instances share one Proton port, one WireGuard identity, one qBittorrent configuration file, or one runtime state directory.

## Architecture overview

```text
                         one host-wide kill-switch policy
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
  Proton tunnel 1               Proton tunnel ...             Proton tunnel 5
  10.2.0.2                      independent address           10.6.0.2
        │                             │                             │
  NAT-PMP lease                  NAT-PMP lease                  NAT-PMP lease
        │                             │                             │
  /run/proton/lidarr/...         /run/proton/<name>/...        /run/proton/prowlarr/...
        │                             │                             │
        └──── proton-qbittorrent-sync-safe.sh (same code) ─────────┘
                                      │
             ┌────────────────────────┼────────────────────────┐
             │                        │                        │
      qBittorrent API       one-key persistent artifact    Compose recreation
       listen_port          QBT_PUBLISHED_PORT=<n>       TCP+UDP on tunnel IP
             │                        │                        │
             └────────────────────────┼────────────────────────┘
                                      │
                           post-recreate verification
```

## Host availability and storage contract

The five clients share one host and one `/mnt/data` CIFS mount, but they must not share one outage when a rolling operation can isolate it.

- Shared changes recreate one qBittorrent member at a time. The other four remain available for downloading, uploading, and seeding while the changed member passes its health gate.
- Do not globally pause torrents or add queueing, active-upload, or seeding limits as a rollout or incident mitigation. The reconciled member resumes its existing workload after its own gate passes.
- The live SMB 3.1.1 `/mnt/data` mount uses `cache=none`. The policy applies to all five clients and every other `/mnt/data` consumer; it is an active containment measure, not a Sonarr override or a demonstrated kernel repair.
- The recorded 2026-08-17 oops occurred at 19:05 under `cache=strict`; fstab changed at 20:01 and the 20:16 reboot created the first live `cache=none` mount.
- Local incomplete storage is not currently capacity-safe for the fleet. A future layout change belongs in shared policy and requires capacity plus all-five migration and rollback design.

Boot follows two explicit dependency edges. `mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`, which waits for a NAS route and TCP port 445. Docker wants and follows all five Proton WireGuard units. `Wants=` provides ordering and activation attempts, not a guarantee of tunnel health, so the host kill switch and final runtime verification remain mandatory.

Kernel package numbers are not part of the fleet contract. Ubuntu `7.0.0-30.30` has no relevant netfs correction, `7.0.0-31.31` remains proposed-only, and the related Linux 7.1.8/7.2 repairs have not been proven on this workload. A replacement kernel must retain a rollback path and pass the storage gate plus all-five runtime and workload validation.

## Canonical instance catalog

The machine-readable source is `qbittorrent-instances.tsv`. The installed copy is `/opt/qbittorrent-common/qbittorrent-instances.tsv`.

| Instance | Web UI | Legacy port reference | Tunnel bind IP | Interface | Address subnet | Route table | qB rule priority |
| --- | ---: | ---: | --- | --- | ---: | ---: | ---: |
| `lidarr` | 8081 | 51058 | 10.2.0.2 | `pvlidarr` | 2 | 51802 | 112 |
| `prowlarr` | 8082 | 51057 | 10.6.0.2 | `pvprowlarr` | 6 | 51806 | 116 |
| `radarr` | 8083 | 51056 | 10.3.0.2 | `pvradarr` | 3 | 51803 | 113 |
| `sonarr` | 8084 | 51055 | 10.4.0.2 | `pvsonarr` | 4 | 51804 | 114 |
| `whisparr` | 8085 | 51054 | 10.5.0.2 | `pvwhisparr` | 5 | 51805 | 115 |

The legacy port column records the pre-migration static values for incident comparison only. The wrappers do not use them as fallbacks. Compose refuses to render unless the synchronizer explicitly injects the current `QBT_PUBLISHED_PORT`; after boot or reconnect, only a successful NAT-PMP lease is authoritative.

## Sources of truth

### Shared static service policy

Repository source:

```text
qbittorrent-compose.common.yml
```

Installed file:

```text
/opt/qbittorrent-common/docker-compose.common.yml
```

It controls every setting that should be identical across the fleet:

- image and tag;
- UID, GID, umask, and timezone;
- s6 shutdown grace settings;
- Docker stop grace period;
- `/mnt/data:/data` mount;
- health-check command, timing, and thresholds;
- restart policy;
- external Docker network attachment.

Each instance's `docker-compose.yml` extends this service. A wrapper is prohibited from duplicating or overriding these fields unless the fleet architecture document and manifest explicitly classify the field as instance-specific.

### Static project environment

Each file `/opt/qbittorrent-<instance>/.env` contains exactly one assignment:

```dotenv
QBT_HOST_BIND_IP=10.<instance-subnet>.0.2
```

It must not contain:

- `QBT_PUBLISHED_PORT`;
- `QBT_FORWARDED_PORT`;
- a qBittorrent credential;
- a Proton lease;
- a runtime state path.

Comments are permitted. A second assignment is a fleet-verification failure.

### Live Proton lease

The volatile lease for an instance is:

```text
/run/proton/<instance>/proton-port.state
```

Its relevant values are:

```dotenv
CURRENT_PORT=<active NAT-PMP port>
CURRENT_IP=<active tunnel address>
```

`/run` is not persistent. An old persistent artifact must not be treated as a renewed lease after reboot. The port-forward service must obtain or refresh NAT-PMP state first.

### Last successfully applied Docker port

The persistent per-instance artifact is:

```text
/etc/proton/instances/<instance>/qbittorrent-port.env
```

It contains exactly:

```dotenv
QBT_PUBLISHED_PORT=<last successfully applied port>
```

The optional managed comment does not count as an assignment. `QBT_FORWARDED_PORT` is obsolete and prohibited.

The artifact is not automatically loaded as the project `.env`. The synchronizer reads it for comparison and injects the active `QBT_PUBLISHED_PORT` into the specific `docker compose` process. This preserves the project `.env` as a one-key static file.

### qBittorrent application value

qBittorrent's application-level listen port is its Web API `listen_port` preference and its persisted `Session\Port`. Random port selection is disabled by the synchronizer.

### Docker runtime value

The active container must satisfy all of these simultaneously:

```text
container TORRENTING_PORT
= TCP target and published host port
= UDP target and published host port
= QBT_PUBLISHED_PORT
= CURRENT_PORT
= qBittorrent listen_port
```

TCP and UDP deliberately use the same number. Those two protocol mappings are not duplicate environment values.

## Port synchronization transaction

```text
Proton NAT-PMP response
  │
  ├─ validate 1..65535
  ├─ write /run/proton/<instance>/proton-port.state
  └─ invoke proton-qbittorrent-sync-safe.sh <instance>
       │
      ├─ acquire per-instance qB sync lock
      │    normal sync: skip if busy
      │    forced fleet sync: wait, then fail on timeout
       ├─ read CURRENT_PORT
       ├─ validate protected qB environment
       ├─ refuse project .env as QBT_PORT_ENV_FILE
      ├─ inspect container for manual stop, zombie, and persistent D state
       ├─ authenticate to the instance Web API
       ├─ disable random port and set listen_port
       ├─ atomically write one-key persistent artifact
       ├─ QBT_PUBLISHED_PORT=<active> docker compose up --force-recreate
       ├─ wait for the instance Web UI
       ├─ verify qBittorrent listen_port
       ├─ verify Docker TCP mapping
       ├─ verify Docker UDP mapping
       └─ write the per-instance cache only after success
```

On a failed port-changing recreation, the script attempts to restore the previous published artifact and service port. A forced same-port structural recreation has no different port to restore. It must never substitute another instance's port.

## Two kinds of synchronization

### Per-instance runtime synchronization

A Proton lease belongs to one tunnel address. When the lease for Sonarr changes, only `qbittorrent-sonarr` is recreated. Recreating the unrelated four clients would introduce avoidable downtime and CIFS load, and copying Sonarr's port to them would violate Proton's independent NAT-PMP sessions.

This rule is tested and documented as:

```text
one lease change -> one matching qBittorrent recreation
```

### Fleet-wide structural synchronization

A shared image, health check, s6 setting, stop policy, volume policy, init hook, security setting, or shared qBittorrent behavior change applies to all five.

The required workflow is:

```text
edit shared source once
  -> deploy shared source
  -> static parity verification
  -> protected-config preflight
      -> refuse if any member is unhealthy/zombie/persistent-D-state
  -> rolling recreation of all five
  -> per-instance health gate
  -> full runtime parity verification
```

Fleet consistency does not require simultaneous restarts. Sequential, health-gated recreation is safer and is the canonical method.

## Allowed instance differences

Only the following categories are intrinsically per-instance:

- instance/service/container/project name;
- Web UI port;
- legacy port reference in the manifest (never an automatic Compose fallback);
- tunnel subnet and bind IP;
- WireGuard interface and identity;
- NAT-PMP gateway derived from the subnet;
- route table and qBittorrent source-rule priority;
- runtime and persistent state paths;
- qBittorrent credentials;
- category, tag, save path, and workload-specific automation;
- the current Proton lease;
- instance-local config volume.

Any new exception must be added to the manifest or documented as an explicit preference override. “This instance happened to be edited manually” is not an acceptable exception.

## Fleet-controlled qBittorrent preferences

Whole `qBittorrent.conf` files must never be copied between instances. They contain legitimate per-instance paths, Web UI ports, credentials, categories, tags, and live ports.

Shared preferences should instead be managed as a declared key list. During the 2026-08-14 audit, these unexplained differences were found and remain follow-up maintenance work:

- Sonarr `ConnectionSpeed=200`; four-instance baseline `150`.
- Sonarr `FilePoolSize=0`; four-instance baseline `5000`.
- Sonarr `RequestQueueSize=1410065407`; four-instance baseline `2000`.
- Sonarr Web UI UPnP differed from the other four.
- Radarr had an additional-tracker URL not present elsewhere.
- Lidarr had excluded-file filtering not present elsewhere.
- AutoRun behavior differed by workload.

Do not automatically normalize these by copying files. Classify each preference as fleet-controlled or an explicit role override, apply it through a declarative API/config reconciler, and validate the result on all five.

## Routing concurrency model

### Shared route lock

All policy-route mutation uses:

```text
/run/proton/policy-routing.lock
```

It is global and must not derive from per-instance `STATE_DIR`. It covers:

- WireGuard route injection;
- WireGuard route cleanup;
- Docker watcher route reconciliation;
- related raw/mangle rule changes and route-state persistence.

WireGuard setup and teardown treat lock timeout as fatal before route mutation. The long-running watcher logs and skips one reconciliation if it cannot acquire the lock; it remains alive for the next event.

### Shared kill-switch lock

Both nftables and iptables backends use:

```text
/run/proton/killswitch.lock
```

The rulesets are host-wide, so per-instance kill-switch locks would not provide mutual exclusion. The kill-switch must be called outside the policy-route critical section to avoid lock-order coupling.

### Per-instance locks

The following remain isolated by instance:

- recovery lock;
- qBittorrent sync lock;
- allocator coalescing lock;
- state files and caches.

An allocator for Lidarr must not block Prowlarr merely because both need reconciliation; their Proton gateways and leases are independent.

Ordinary lease-driven synchronization takes its per-instance lock non-blocking and may skip because the long-running port-forward loop will retry. A forced fleet recreation waits up to `QBT_SYNC_LOCK_WAIT_SECONDS` and exits nonzero on timeout. It must never report a skipped instance as a successful structural rollout.

## Failure boundaries

### Normal application failure

If the Web UI is unavailable but processes are killable and the container is not manually stopped, one guarded recreation may be attempted.

### Docker/runtime wedge

If the named container remains running with no published ports or contains a zombie, normal self-heal is refused to prevent orphan/name-conflict loops.

### Kernel I/O wedge

Transient `D` state can occur during ordinary CIFS I/O. Automation samples LWP IDs and refuses recreation only when the same task remains uninterruptible across the configured samples. Persistent `D` state, especially with `folio_wait_bit_common` and a netfs/CIFS kernel trace, makes the host kernel the recovery boundary. Automation must not keep issuing Compose, Docker remove, cgroup kill, shim kill, or signal operations.

## Verification layers

### Static layer

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only
```

This verifies the shared policy, wrappers, one-key project `.env` files, Compose resolution, and identical init hooks.

### Protected configuration layer

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config
```

This additionally validates each root-owned Proton/qBittorrent env and one-key persistent artifact.

### Runtime layer

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

This additionally requires runtime state, tunnel IP, container environment, qBittorrent persisted port, authenticated API listen port, exact TCP mapping, exact UDP mapping, container source policy rule, running state, and healthy state to agree.

### Fleet structural rollout

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The reconciler preflights the entire fleet before changing the first member, refuses unhealthy/zombie/persistent-`D`-state baselines, waits for forced per-instance sync locks, recreates sequentially, stops at the first failed health gate, and runs final runtime verification itself.

## Security invariants

- No torrent port may bind to `0.0.0.0`; it binds to the instance tunnel IP.
- The Web UI publication remains separate from the torrent bind address.
- Protected credentials and instance env files remain root-owned mode `0600`.
- Dynamic port artifacts remain root-owned mode `0600`.
- Systemd executes installed programs under `/usr/local/bin/proton`, never a writable development checkout.
- Docker application egress remains subject to the host kill-switch.
- A configuration verifier must not print credentials.

## Archive status

`/archive` was absent when this contract was written. No architectural conclusion here depends on an archived implementation.
