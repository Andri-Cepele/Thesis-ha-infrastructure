# Incident 03 — Failover Testing Uncovers Two Independent Boot-Order Races

## Summary

Deliberate failover testing (powering off each worker node in turn, post-recovery from Incidents 01–02) confirmed Swarm's basic failover works, but a second round of testing — rebooting nodes fully rather than just shutting them down — uncovered two separate boot-order race conditions that had been silently present since the cluster was first built. Neither would show up in normal operation; both only surface when a GlusterFS peer node actually reboots.

## Test 1 — worker1 powered off (soft shutdown)

- 5 services were running on worker1 at the time: Nextcloud (app + DB), Immich-server.
- Recovery time to `Running` on worker2: ~2–3 minutes, including one transient `Rejected` retry per service (`failed to lookup digest: Canceled: context canceled` — a momentary registry-lookup hiccup during simultaneous rescheduling, self-resolved by Swarm's own retry policy).
- On worker1's return: GlusterFS reported the expected pending-heal entries (data written to the surviving brick while worker1 was down); heal converged to 0/0 (heal pending / split-brain) within a few minutes, unassisted.
- **Result: full success**, zero data loss, zero manual intervention needed on this node's own return.

## Test 2 — worker2 powered off

- All 5 services had, by this point, already migrated onto worker2 from Test 1's redistribution and had not been rebalanced back — so this test exercised moving all 5 services back onto worker1 simultaneously, a harder case than Test 1.
- On worker2's return, `mount | grep gluster` showed only the local XFS brick mount — **the GlusterFS client mount (`/mnt/gluster`) had not come up automatically**, despite an fstab entry with `_netdev`.

### Root cause 1 — disk identifier drift

Investigating via the Proxmox console (worker2 had also failed to boot at all initially, dropping into emergency mode — see below), `lsblk` revealed the local disk naming had swapped: the OS/swap disk was now `/dev/sdb` and the GlusterFS brick disk was now `/dev/sda` — the reverse of their previous assignment. `/etc/fstab` referenced the brick by its old device name (`/dev/sdb`), which after the swap pointed at the OS disk instead, causing a hard mount failure during boot (`Can't open blockdev`) and dropping the whole system into `systemd` emergency mode.

**Device names under `/dev/sdX` are not guaranteed stable across reboots for virtualized/attached disks** — this is a known class of problem, not specific to this hardware, and the fix is standard: reference filesystems by UUID, never by device path.

```bash
blkid /dev/sda   # get the real UUID
# then in /etc/fstab, replace /dev/sdX with:
UUID=<uuid-from-blkid> /data/gluster/brick xfs defaults,noatime 0 0
```

Applied to **both** worker nodes as a precaution — worker1 hadn't drifted yet, but had the identical latent risk (same `/dev/sdX`-based fstab entry).

### Root cause 2 — Tailscale-before-mount race

With the disk UUID fixed and the system out of emergency mode, GlusterFS still didn't mount automatically on the *next* reboot. `_netdev` in fstab guarantees systemd waits for the base network target, but Tailscale is an overlay network on top of that — `tailscaled.service` being started is not the same as the `tailscale0` interface having an IP yet. There is a real, several-second gap between the two on boot, and a mount attempted inside that gap fails outright.

**Fix**: `systemd/wait-for-tailscale.service` + `wait-for-tailscale.sh` — polls the `tailscale0` interface directly for a real IP (not `tailscale status --json`'s "Online" field, which reflects peer reachability across the whole tailnet and is unreliable to parse for "is *this* node's own connection up" via simple line-based tools against multi-line JSON) before allowing the GlusterFS mount unit to proceed (`Before=mnt-gluster.mount`, plus the fstab entry updated with `x-systemd.requires=wait-for-tailscale.service`).

Confirmed working on both nodes on the next real reboot: `Tailscale eshte online pas 2s` in the unit's journal, `/mnt/gluster` mounted automatically with zero manual intervention.

### Root cause 3 — GlusterFS brick doesn't reliably self-start

Fixing the Tailscale race was necessary but not sufficient — a *second*, independent race remained. On a subsequent reboot, `wait-for-tailscale.service` succeeded immediately, but the mount still failed. `gluster volume status` showed the local brick reporting `Online: N` — `glusterd` itself had started, but had not brought the actual brick process up. This did not resolve on its own even after waiting; it required an explicit `gluster volume start <volume> force`.

**Fix**: `systemd/wait-for-gluster.service` + `wait-for-gluster.sh` — unconditionally force-starts the local brick, then polls `gluster volume status --xml` (matched against this node's own Tailscale IP specifically) until it reports online, with a 60-second safety margin. Also required an `ExecStartPost` to explicitly re-trigger the `/mnt/gluster` mount, because **once a systemd `.mount` unit has failed once during boot, systemd does not automatically retry it just because a dependency later succeeds** — it has to be told to mount again.

Confirmed on repeated real reboots of both nodes, independently, after the fix: both mounts (`brick` and `/mnt/gluster`) come up automatically with zero manual steps, every time.

## A genuine false positive, caught by the new monitoring

During this round of testing — glusterd being restarted/force-started repeatedly in a short window — Grafana fired a **CRITICAL "GlusterFS SPLIT-BRAIN Detected"** alert email. Cross-checked immediately against `gluster volume heal <volume> info split-brain` directly: **zero real split-brain entries on either brick.** The alert had fired because the underlying health-check script's `gluster volume heal` command itself failed transiently (`Not able to fetch volfile from glusterd`, a normal transient state right after a glusterd restart) — and the script's original fallback logic (`${SPLIT_BRAIN:-1}`) treated *any* command failure as worst-case "split-brain: 1", rather than distinguishing "the check didn't run" from "the check ran and found a real problem."

Fixed in `scripts/gluster-heal-check.sh`: a dedicated `gluster_check_failed` metric now reports when the health-check command itself couldn't execute, kept entirely separate from the real heal/split-brain counts — so a transient monitoring hiccup can no longer masquerade as a data-integrity emergency.

## A related, smaller finding — Jellyfin's restart cap

Amid the same testing, Jellyfin was found stuck in a permanently `Rejected` state after a GlusterFS mount hiccup, while every *other* service on the same node kept retrying and eventually recovered on its own. Cause: Jellyfin's `restart_policy` had a `max_attempts: 3` cap that none of the other stacks had — it simply ran out of retries during the mount race window before the underlying fix above was in place. Removed the cap and extended `delay` to 40s in `stacks/jellyfin/docker-compose.yml`, matching the retry behavior of every other service in the cluster.

## Full end-to-end verification

After all three fixes above, the following were each independently tested with **actual reboots**, not simulations:

- worker1 rebooted alone → both GlusterFS mounts come up automatically. ✅
- worker2 rebooted alone → both GlusterFS mounts come up automatically. ✅
- Manager (rpi) rebooted alone → Traefik, Prometheus, Grafana (all manager-only) come back to `1/1` automatically; every backend service on the workers was completely unaffected throughout. ✅
- A full application-level smoke test during a worker outage (not just checking container status): deleted a photo in Immich, uploaded a document to Nextcloud, and played a video in Jellyfin, all successfully, while the other worker was powered off — full recovery time to a usable UI on the surviving node was approximately one minute. ✅

## Deliberately not tested

Simultaneously rebooting both worker nodes at (or near) the same time was considered and explicitly **not** attempted, as a judgment call: with both GlusterFS replicas offline at once there is no surviving copy to serve from, so the value of confirming that edge case was judged lower than the risk of turning a test into a real recovery. The safe procedure for a planned full-cluster restart is covered in [the shutdown/startup runbook](../runbooks/safe-shutdown-startup.md). Documented here as a known gap in test coverage rather than silently skipped.
