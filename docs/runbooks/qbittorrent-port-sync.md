# Runbook: qBittorrent and Proton port synchronization

## Objective

For every managed instance, prove that the active Proton NAT-PMP lease, qBittorrent listen port, persistent port artifact, Docker container environment, and both Docker protocol mappings are identical—while keeping the five instances isolated from one another.

## Scope

This runbook applies to:

```text
lidarr prowlarr radarr sonarr whisparr
```

Run commands from the host. Root access is required for files under `/etc/proton` and `/run/proton`.

## Non-negotiable state model

### Static project `.env`

Path:

```text
/opt/qbittorrent-<instance>/.env
```

Exactly one assignment is allowed:

```dotenv
QBT_HOST_BIND_IP=10.<subnet>.0.2
```

This file is read automatically by Docker Compose. It does not store a port.

### Live Proton lease

Path:

```text
/run/proton/<instance>/proton-port.state
```

Expected data:

```dotenv
CURRENT_PORT=<active-port>
CURRENT_IP=<tunnel-ip>
```

This is volatile. It disappears or becomes invalid across a reboot/reconnect until NAT-PMP succeeds again.

### Last applied Docker port

Path:

```text
/etc/proton/instances/<instance>/qbittorrent-port.env
```

Exactly one assignment is allowed:

```dotenv
QBT_PUBLISHED_PORT=<last-applied-port>
```

`QBT_FORWARDED_PORT` is obsolete and must not exist. The artifact is persistent evidence of what was last applied; it is not proof that Proton renewed the same lease after reboot.

### Protected instance orchestration config

Path:

```text
/etc/proton/instances/<instance>/qbittorrent.env
```

It defines identity, credentials, Compose project/service, network, apply mode, and artifact path. It must not define either dynamic port key.

## Instance matrix

| Instance | Web UI | Bind IP | Interface | State/artifact namespace |
| --- | ---: | --- | --- | --- |
| Lidarr | 8081 | 10.2.0.2 | `pvlidarr` | `lidarr` |
| Prowlarr | 8082 | 10.6.0.2 | `pvprowlarr` | `prowlarr` |
| Radarr | 8083 | 10.3.0.2 | `pvradarr` | `radarr` |
| Sonarr | 8084 | 10.4.0.2 | `pvsonarr` | `sonarr` |
| Whisparr | 8085 | 10.5.0.2 | `pvwhisparr` | `whisparr` |

## Normal automatic flow

1. `proton-wg@<instance>` establishes that instance's tunnel.
2. `proton-port-forward@<instance>` requests or refreshes a NAT-PMP lease through that instance's derived gateway.
3. The port-forward loop writes `CURRENT_PORT` and `CURRENT_IP` in `/run/proton/<instance>`.
4. It invokes `proton-qbittorrent-sync-safe.sh <instance>`.
5. The synchronizer acquires `/run/proton/<instance>/qbt-sync.lock`.
6. It rejects missing, nonnumeric, zero, or greater-than-65535 ports.
7. It rejects `QBT_PORT_ENV_FILE` if it points to the Compose project's static `.env`.
8. It honors an intentional manual stop.
9. It refuses normal Compose work for zombie, no-port, or kernel `D`-state wedges.
10. It authenticates to the correct qBittorrent Web API.
11. It disables qBittorrent random-port selection.
12. It applies the active port to qBittorrent.
13. It writes the one-key port artifact atomically using a temporary file, mode `0600`, and rename.
14. It injects `QBT_PUBLISHED_PORT` into the matching Compose process.
15. It stops/recreates only `qbittorrent-<instance>`.
16. It waits for the Web UI.
17. It verifies qBittorrent reports the target port.
18. It verifies Docker publishes the port for both TCP and UDP.
19. It commits the per-instance cache and reports success.

An unchanged lease does not normally recreate the container. If the artifact is in the legacy two-key format, the script canonicalizes it to one key without an unnecessary restart.

## Preflight

### 1. Verify static fleet shape

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only
```

Expected result:

```text
Fleet verification passed for all 5 qBittorrent instances.
```

This command must pass before changing a port-sync script, Compose policy, wrapper, project `.env`, or init hook.

### 2. Verify protected configuration

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config
```

This fails if any instance has:

- the wrong identity/path/network/interface/table;
- a project `.env` with more than one assignment;
- a dynamic port in a project `.env`;
- a persistent artifact with more than one assignment;
- the obsolete alias;
- a missing or invalid port;
- a port artifact path that differs from the per-instance path.

### 3. Inspect service state

```bash
for instance in lidarr prowlarr radarr sonarr whisparr; do
  systemctl status "proton-wg@${instance}.service" \
    "proton-port-forward@${instance}.service" \
    "proton-docker-watch@${instance}.service" \
    "proton-healthcheck@${instance}.service" \
    --no-pager -l
done
```

Do not start a forced fleet rollout if one member is already unhealthy. Diagnose it first.

## Manual per-instance synchronization

Use the allocator unit rather than bare Compose:

```bash
sudo systemctl start proton-qbt-allocate@sonarr.service
sudo systemctl status proton-qbt-allocate@sonarr.service --no-pager -l
```

Replace `sonarr` with the target instance. The allocator validates the instance name, starts/observes the matching port-forward service, waits for its state file, and invokes the installed sync script.

Direct diagnostic invocation is also possible:

```bash
sudo /usr/local/bin/proton/proton-qbittorrent-sync-safe.sh sonarr
```

Do not run an unqualified `docker compose up` to “fix” a port. The wrappers intentionally refuse to render without an explicitly injected `QBT_PUBLISHED_PORT`; use the allocator/synchronizer so that value comes from the matching live Proton lease.

## Verify one instance manually

The following example uses Sonarr. Substitute the instance matrix values for another client.

### Read state without exposing credentials

```bash
sudo awk -F= '/^(CURRENT_PORT|CURRENT_IP)=/ {print}' \
  /run/proton/sonarr/proton-port.state
sudo awk -F= '/^QBT_PUBLISHED_PORT=/ {print}' \
  /etc/proton/instances/sonarr/qbittorrent-port.env
```

### Confirm artifact schema

```bash
sudo awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {count++} END {print count+0}' \
  /etc/proton/instances/sonarr/qbittorrent-port.env
```

Expected output is `1`.

```bash
sudo grep -n '^QBT_FORWARDED_PORT=' \
  /etc/proton/instances/sonarr/qbittorrent-port.env
```

Expected: no output and exit status `1`.

### Confirm container environment and bindings

```bash
docker inspect qbittorrent-sonarr --format \
  '{{range .Config.Env}}{{println .}}{{end}}' | grep '^TORRENTING_PORT='

docker inspect qbittorrent-sonarr --format \
  '{{range $port,$items := .HostConfig.PortBindings}}{{range $items}}{{printf "%s %s:%s\n" $port .HostIp .HostPort}}{{end}}{{end}}'
```

Expected:

- `TORRENTING_PORT` equals `CURRENT_PORT`;
- one `<port>/tcp 10.4.0.2:<port>` entry;
- one `<port>/udp 10.4.0.2:<port>` entry;
- no torrent bind on `0.0.0.0`.

### Confirm persisted qBittorrent port

```bash
awk -F= '$1 == "Session\\Port" {print $2}' \
  /opt/qbittorrent-sonarr/config/qBittorrent/qBittorrent.conf
```

The Web API check is stronger because a running qBittorrent may not have flushed every preference to disk yet. Use the configured credentials without printing them:

```bash
sudo /usr/local/bin/proton/proton-qbittorrent-sync-safe.sh sonarr
```

The script performs authenticated post-apply verification internally.

## Verify the complete fleet

After a reboot, reconnect, deployment, or structural rollout:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

This is the acceptance gate. It verifies every instance, not merely the one that was most recently changed.

## Expected behavior on a new Proton port

For an example Sonarr change from `51055` to `54105`:

```text
/run/proton/sonarr/proton-port.state -> CURRENT_PORT=54105
qBittorrent API                    -> listen_port=54105
/etc/proton/.../qbittorrent-port.env -> QBT_PUBLISHED_PORT=54105
Compose process environment        -> QBT_PUBLISHED_PORT=54105
container environment              -> TORRENTING_PORT=54105
Docker host mapping                -> 10.4.0.2:54105 TCP and UDP
```

Only `qbittorrent-sonarr` is recreated. The other four retain their own live ports.

## Forced recreation for a shared fleet change

Do not call the per-instance force flag five times manually. Use the health-gated fleet tool:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The tool:

1. validates all protected configuration;
2. refuses before the first change if any member is absent, unhealthy, zombie, or in `D` state;
3. invokes the same synchronizer for each instance with `QBT_FORCE_RECREATE=1`;
4. preserves each instance's own active port;
5. waits for health before moving to the next instance;
6. runs full runtime verification at the end.

## Failure handling

### No `CURRENT_PORT`

Do not use the persistent artifact as if it were a renewed lease. Inspect the WireGuard and port-forward units:

```bash
sudo systemctl status proton-wg@sonarr.service proton-port-forward@sonarr.service --no-pager -l
sudo journalctl -u proton-wg@sonarr.service -u proton-port-forward@sonarr.service -n 250 --no-pager
```

Repair the tunnel/lease path first.

### `RTNETLINK answers: File exists`

Confirm the installed scripts include the global policy-route lock and match source. Then inspect all instance units; do not fix only the failed instance. Route mutations must be serialized fleet-wide.

### systemd `203/EXEC`

Verify:

```bash
systemctl cat proton-qbt-allocate@.service
stat -c '%a %U:%G %n' /usr/local/bin/proton/proton-qbt-allocate-and-sync.sh
```

Expected:

```text
ExecStart=/usr/local/bin/proton/proton-qbt-allocate-and-sync.sh %i
755 root:root /usr/local/bin/proton/proton-qbt-allocate-and-sync.sh
```

No systemd unit may execute from `/usr/local/bin/proton_project`.

### Web UI unreachable

The synchronizer distinguishes:

- intentional manual stop: skip;
- ordinary running failure: one guarded self-heal;
- running/no published ports: refuse;
- zombie: refuse;
- uninterruptible `D` state: refuse and require host recovery.

Use `docs/runbooks/qbittorrent-wedge-recovery.md` before issuing more Docker commands.

### Compose recreation fails on a busy port

The synchronizer retries only the recognized address-in-use/allocated-port failure. After its configured attempts, it restores the previous artifact and tries to restore the previous service mapping. Investigate the port owner:

```bash
sudo ss -lntup | grep ':<port>'
docker ps -a --format '{{.Names}} {{.Ports}}' | grep ':<port>'
```

Never solve a collision by binding the torrent port to `0.0.0.0`.

## Post-change evidence to retain

For each instance, retain:

- active Proton server/profile;
- interface and tunnel address;
- runtime `CURRENT_PORT` and `CURRENT_IP`;
- persistent `QBT_PUBLISHED_PORT`;
- container health and `TORRENTING_PORT`;
- TCP and UDP host bindings;
- qBittorrent API-reported listen port;
- source policy rule and route table;
- relevant synchronizer journal lines;
- final fleet verifier result.

Do not retain or paste qBittorrent passwords, cookie jars, or WireGuard private keys.
