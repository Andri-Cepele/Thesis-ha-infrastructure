#!/bin/bash
# Install to /root/backup-databases.sh (or similar) on EVERY worker node, and
# schedule identically via cron on each — e.g.:
#   0 3 * * * /root/backup-databases.sh >> /root/backups/backup.log 2>&1
#
# Because services can migrate between nodes (Swarm failover, or manual
# rebalancing), this script is written to detect on its own whether the
# Nextcloud or Immich database is currently running on the node it's
# executing on, and only backs up what's actually local. Deploy the same
# script unmodified to both workers.
#
# Backups are written to LOCAL disk (not the GlusterFS mount) so that a
# GlusterFS-level problem can never take out backups along with the live
# data. Restores from these backups were tested end-to-end in an isolated,
# disposable container (never against the live database) — see
# docs/runbooks/disaster-recovery-restore.md for that exact procedure.

# cron runs with an almost empty environment, so load the DB credentials
# explicitly from a root-only file (chmod 600) instead of relying on exports.
ENV_FILE="/root/.homelab.env"
if [ -f "$ENV_FILE" ]; then
    set -a; . "$ENV_FILE"; set +a
fi

DATE=$(date +%F)
BACKUP_DIR="/root/backups"
mkdir -p "$BACKUP_DIR"

# Nextcloud DB (only if it's running on this node)
NEXTCLOUD_DB=$(docker ps -q -f name=nextcloud_nextcloud-db)
if [ -n "$NEXTCLOUD_DB" ]; then
    docker exec "$NEXTCLOUD_DB" mariadb-dump -u "${NEXTCLOUD_DB_USER}" -p"${NEXTCLOUD_DB_PASSWORD}" "${NEXTCLOUD_DB_NAME}" \
        > "$BACKUP_DIR/nextcloud_${DATE}.sql"
    echo "Nextcloud DB backup: OK ($DATE)"
fi

# Immich DB (only if it's running on this node)
IMMICH_DB=$(docker ps -q -f name=immich_immich-db)
if [ -n "$IMMICH_DB" ]; then
    docker exec "$IMMICH_DB" pg_dump -U "${IMMICH_DB_USER}" -d "${IMMICH_DB_NAME}" -F c -f /tmp/immich_backup.dump
    docker cp "$IMMICH_DB":/tmp/immich_backup.dump "$BACKUP_DIR/immich_${DATE}.dump"
    echo "Immich DB backup: OK ($DATE)"
fi

# Retain 14 days of local backups
find "$BACKUP_DIR" -type f -mtime +14 -delete
