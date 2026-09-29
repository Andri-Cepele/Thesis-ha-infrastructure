# Deployment Notes

This repo is a **documentation and configuration reference**, not a one-command installer — the underlying hardware (Proxmox hosts, Tailscale identities, GlusterFS bricks) is specific to the original setup and has to exist first. That said, the compose files and scripts here are directly reusable. Notes on wiring them up:

## Environment variables

Every stack file references variables like `${NEXTCLOUD_DB_PASSWORD}` rather than hardcoding secrets. Note that `docker stack deploy`, unlike `docker compose up`, does **not** read a `.env` file by itself: it only substitutes variables that are already set in the calling shell. Export them first:

```bash
cp .env.example .env          # then edit .env with real values (never commit it)
set -a; source .env; set +a   # export every variable in .env
cd stacks/nextcloud && docker stack deploy -c docker-compose.yml nextcloud
```

`stacks/monitoring/prometheus.yml` is the exception: Prometheus never expands environment variables in its own config, so replace the `<...>` placeholders in that file directly.

For the cron-driven `scripts/backup-databases.sh`, put the same variables in a root-only file (`/root/.homelab.env`, `chmod 600`); the script loads it itself because cron does not inherit your shell environment.

## Prerequisites this repo assumes already exist

- A Docker Swarm cluster already initialized, with node labels applied:
  ```bash
  docker node update --label-add glusterfs=true <worker1-hostname>
  docker node update --label-add glusterfs=true <worker2-hostname>
  ```
- The external overlay network referenced by every stack:
  ```bash
  docker network create --driver overlay --attachable proxy-net
  ```
- GlusterFS already configured as a replica-2 volume named `swarm-data`, mounted at `/mnt/gluster` on every GlusterFS-labeled node (see `systemd/` for the boot-reliability units, and `docs/architecture.md` for the reasoning behind the setup).
- Tailscale installed and authenticated on every node, with MagicDNS enabled if you want stable hostnames instead of raw IPs.

## Deploy order

Matches the dependency order used throughout this repo's incident reports — ingress and observability first, then applications, Nextcloud last (it has the most moving parts: app + DB + Redis, all constrained to GlusterFS nodes):

```bash
for stack in traefik monitoring jellyfin immich nextcloud; do
  cd stacks/$stack
  docker stack deploy -c docker-compose.yml $stack
  cd ../..
done
```

## Alert rules

`stacks/monitoring/alert-rules/*.json` are sanitized templates (placeholder datasource UID, placeholder IPs) reflecting the actual rules running in production, not directly importable as-is. Re-create them via Grafana's Alerting UI, or adapt them into calls against the provisioning API (`POST /api/v1/provisioning/alert-rules`) after substituting your own Prometheus datasource UID and node IPs.
