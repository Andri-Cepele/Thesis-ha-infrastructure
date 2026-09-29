# Runbook: Safe Full-Cluster Shutdown and Startup

Use this whenever powering the whole cluster down deliberately (moving hardware, extended absence, maintenance) rather than testing a single node's failure. Short power cycles of a single node are what regular HA failover is for and don't need this procedure — see [incident report 03](../incident-reports/03-failover-testing-and-boot-races.md) for what that looks like tested end-to-end.

## Before shutting anything down

Confirm GlusterFS has nothing in flight:

```bash
# on either worker
gluster volume heal swarm-data info summary
```

Both bricks should show `Number of entries in heal pending: 0` and `Number of entries in split-brain: 0`. Do not proceed with a full shutdown if either is non-zero — wait for it to settle first.

## Shutdown order

1. **Workers first** (worker1, then worker2 — order between the two doesn't matter, just do them before the manager):
   ```bash
   systemctl stop docker
   umount /mnt/gluster
   poweroff
   ```
2. **Manager last** (rpi):
   ```bash
   poweroff
   ```

Rationale: shutting workers down first lets Swarm see clean node departures rather than the manager going dark while workers are still trying to report to it, and unmounting GlusterFS cleanly before power-off avoids any filesystem journal inconsistency risk on the brick disks.

## Startup order

1. Power on the physical hosts / Proxmox hypervisors first, and let worker1/worker2 VMs auto-start (assuming "Start at boot" is enabled on them).
2. Power on the manager (rpi) — Swarm's manager should re-establish leadership automatically.
3. Wait 1–2 minutes for everything to settle, then verify, on the manager:
   ```bash
   docker node ls          # all three nodes should show Ready / Active
   ```
   On each worker:
   ```bash
   mount | grep gluster    # both the XFS brick AND /mnt/gluster should appear automatically
   gluster volume status   # both bricks Online: Y
   ```
   Back on the manager:
   ```bash
   docker service ls       # everything at desired replica count (N/N)
   ```

If the GlusterFS mounts do **not** come up automatically at this point, the systemd units in `systemd/` (`wait-for-tailscale.service`, `wait-for-gluster.service`) are either not installed on that node or not enabled — see their inline documentation for the exact race conditions they exist to prevent. With both installed and enabled, this has been confirmed to work with zero manual intervention across multiple real reboot tests.

## The one rule worth remembering

If the cluster has been powered off for anywhere near — or longer than — 90 days, check the Swarm TLS certificate expiry **before** assuming anything else is wrong:

```bash
openssl x509 -enddate -noout -in /var/lib/docker/swarm/certificates/swarm-node.crt
```

This single check would have immediately identified the root cause of [Incident 01](../incident-reports/01-swarm-cert-expiry-and-recovery.md), rather than the hour it actually took to diagnose from symptoms alone.
