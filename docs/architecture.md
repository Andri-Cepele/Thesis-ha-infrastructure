# Architecture

## Physical layout

- **rpi-manager**: Raspberry Pi 4B, boots from SD card. Runs headless, connected via Tailscale.
- **worker1**: VM on a Proxmox host at physical site A.
- **worker2**: VM on a *separate* Proxmox host at a different physical site B, reachable only via Tailscale — there is no shared local network between worker1 and worker2, or between either worker and the manager.

This last point matters: every piece of inter-node traffic in this cluster — Swarm control-plane, GlusterFS replication, application traffic — crosses a WireGuard-encrypted Tailscale mesh, not a LAN. Several of the incidents documented in this repo trace back to that fact (nodes booting before Tailscale is actually ready, not just started).

## Why the manager stays outside GlusterFS

The manager's only local storage is an SD card. SD cards have limited write endurance compared to SSDs/HDDs, and GlusterFS brick or arbiter duty means continuous write traffic. The trade-off analysis:

- **Cost of including rpi as a GlusterFS arbiter**: accelerated SD card wear over the diploma's operational lifetime; a hardware failure mode that's harder to recover from than a normal VM crash.
- **Benefit**: closes a theoretical split-brain window if worker1 and worker2 ever lose direct connectivity to each other while both remain independently reachable by clients (a Tailscale-specific partition scenario, not a simple "one node goes down" failure — see [Split-brain considerations](#split-brain-considerations) below).

Given the low probability of that specific partition scenario on this mesh topology, and the real, certain cost to the SD card, the arbiter was designed, prototyped in discussion, and **deliberately not implemented**. This is documented as a conscious engineering trade-off, not an oversight — see the "Known limitations" section of the main README.

## Split-brain considerations

GlusterFS split-brain requires two bricks to independently accept writes while unaware of each other — which is different from one node simply going offline. Every failover test performed against this cluster (see [incident report 03](incident-reports/03-failover-testing-and-boot-races.md)) was a clean node-down scenario: one brick disappears entirely, the survivor is unambiguously the source of truth, and self-heal on rejoin was confirmed to converge to zero pending entries and zero split-brain entries every time, across four independent tests.

The remaining theoretical risk is a network partition *specifically between worker1 and worker2* that leaves both still reachable by the manager/clients through separate paths — plausible in principle on any mesh network, assessed as unlikely enough on this specific two-site Tailscale topology not to justify the arbiter trade-off above.

## Placement constraints

Two Docker node labels drive scheduling:

- `node.role == manager` — Traefik, Prometheus, Grafana. Manager-only, control-plane and ingress duties.
- `node.labels.glusterfs == true` — set on worker1 and worker2. Nextcloud, Immich, and Jellyfin are all constrained to these nodes.

The GlusterFS constraint exists specifically to prevent Nextcloud's database (or any stateful service) from being scheduled onto a node — like the manager — that isn't a GlusterFS peer and has no mounted volume to write to. Losing this label after a Swarm state rebuild (which happened during the certificate-expiry incident — labels live in Swarm's raft state, not on disk) is an easy and easy-to-miss failure mode; re-applying it is part of the manager-recovery runbook.

## Boot-order dependencies (the two race conditions)

Two independent, non-obvious boot races were found only through deliberate failure testing, not through normal operation:

1. **Tailscale-before-mount**: `_netdev` in `/etc/fstab` guarantees the *base* network is up before a mount is attempted, but does not guarantee an *overlay* network like Tailscale has finished associating and assigned an IP. Fixed with `wait-for-tailscale.service` (see `systemd/`).
2. **GlusterFS-brick-before-mount**: even with Tailscale confirmed up, the local GlusterFS brick process itself does not reliably self-start after certain reboots, and a `.mount` unit that fails once during boot is not automatically retried by systemd even after its dependency later succeeds. Fixed with `wait-for-gluster.service`, which force-starts the brick and explicitly re-triggers the mount.

Both are covered in full, including the diagnostic process that found them, in [incident report 03](incident-reports/03-failover-testing-and-boot-races.md).

## Image versioning policy

After an incident where a floating `:release` tag on Immich silently pulled a breaking major version months after initial deployment (see [incident report 02](incident-reports/02-immich-pgvecto-migration.md)), the policy going forward is: pin every production service to either an explicit version tag or a content digest, never a floating tag (`:latest`, `:release`, `:stable`). Jellyfin and Immich are pinned as of this repository; other services (Traefik, Prometheus, Grafana, MariaDB, Redis) were already on explicit version tags from the start and are unaffected.
