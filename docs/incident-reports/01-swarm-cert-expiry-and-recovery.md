# Incident 01 — Swarm TLS Certificate Expiry After Extended Downtime

## Summary

After the cluster was powered off for approximately three to four months (May–September), every node failed to rejoin or operate as a Swarm member on power-up. Root cause: Docker Swarm's internal TLS certificates expire and rotate automatically on a 90-day cycle — but only while the node is running to receive the rotation. Left powered off past that window, every node's certificate was simply expired on boot, and Swarm refused to initialize at all.

## Symptoms

- `docker node ls` on the manager: `Error: This node is not a swarm manager.`
- `docker info | grep -i swarm` on every node: `Swarm: error — ... certificate ... not valid after ... x509: certificate has expired`
- Separately, `sudo docker node ls` on the manager also failed with a plain permission error — an unrelated, simultaneous issue (the `pi` user was never added to the `docker` group), which briefly obscured the real certificate problem during initial triage.

## Diagnosis process

1. Confirmed Docker daemon itself was healthy (`systemctl status docker` — active) on the manager; only the Swarm subsystem was erroring.
2. Confirmed the certificate expiry timestamp against the current date to establish it was a genuine expiry, not a clock-skew issue.
3. Inspected `/var/lib/docker/swarm/` directly: `raft/` (containing `snap-v3-encrypted` and `wal-v3-encrypted`) confirmed the manager's Swarm state was intact on disk — this was a certificate problem, not a lost/corrupted cluster state.

## Recovery

Manager (rpi):
```bash
systemctl stop docker
mv /var/lib/docker/swarm/certificates /var/lib/docker/swarm/certificates.bak
systemctl start docker
docker swarm init --force-new-cluster --advertise-addr <MANAGER_TAILSCALE_IP>
```

`--force-new-cluster` generates a fresh CA and certificates while attempting to preserve the existing raft log. In this case, the raft snapshot was old enough (and the manager's own node ID changed as part of the forced re-init) that `docker service ls` came back completely empty post-recovery — service definitions were **not** recovered from raft.

This is why the actual recovery path was:
1. Re-join both workers to the freshly initialized swarm with `docker swarm join`.
2. Re-apply the `glusterfs=true` node labels (these also live in raft and did not survive the reset).
3. Re-create the external overlay networks (`proxy-net`, and any per-stack internal networks) — these are also raft-managed and do not persist through a forced re-init.
4. Re-run `docker stack deploy` for every stack from the compose files kept on local disk under `/opt/stacks/` — **critically, these survived intact** because they were never inside Swarm's raft state to begin with, just plain files on the manager's filesystem.

## Key takeaway

**Keep your stack definitions on disk, outside of Swarm's internal state, always.** The certificate/raft loss here would have been a full rebuild-from-memory disaster if the `docker-compose.yml` files for every service hadn't already been sitting in `/opt/stacks/` on the manager's local filesystem. GlusterFS-backed application *data* (photos, documents, media) was never at risk in this incident either way — Swarm state and GlusterFS volumes are entirely independent failure domains.

## Follow-up hardening

- No automated alert exists for an approaching certificate expiry. Manual calendar reminder set for ~2 weeks before the next 90-day boundary (new cert expires ~10 December, based on the September recovery date) as an interim mitigation; a proper Prometheus alert on certificate expiry is a natural next step (not yet implemented).
- This incident is the direct reason the [image versioning policy](../architecture.md#image-versioning-policy) and [full-cluster shutdown/startup runbook](../runbooks/safe-shutdown-startup.md) exist.
