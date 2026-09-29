# Runbook: Restoring a Database Backup (Tested Procedure)

`scripts/backup-databases.sh` runs nightly via cron on both workers, dumping whichever of Nextcloud's or Immich's databases happens to be running locally at the time. This document is the tested procedure for actually restoring from one of those dumps — into a throwaway, isolated container first, never directly against the live service.

**Why an isolated container first:** a backup that has never been restored is not a verified backup, only a hopeful one. Restoring into a disposable container with no port exposure and no shared network with the live stack lets you confirm the dump is valid and complete with zero risk to production data, before ever touching the real thing.

## Nextcloud (MariaDB)

```bash
# 1. Spin up a throwaway MariaDB container — note: no -p port mapping, and it
#    joins Docker's default isolated bridge network, not any stack's network.
docker run -d --name test-restore-nextcloud \
  -e MARIADB_ROOT_PASSWORD=testpass123 \
  -e MARIADB_DATABASE="${NEXTCLOUD_DB_NAME}" \
  -e MARIADB_USER="${NEXTCLOUD_DB_USER}" \
  -e MARIADB_PASSWORD="${NEXTCLOUD_DB_PASSWORD}" \
  mariadb:10.11

sleep 15   # let MariaDB finish initializing

# 2. Restore the most recent backup into it
LATEST=$(ls -t /root/backups/nextcloud_*.sql | head -1)
docker exec -i test-restore-nextcloud mariadb \
  -u "${NEXTCLOUD_DB_USER}" -p"${NEXTCLOUD_DB_PASSWORD}" "${NEXTCLOUD_DB_NAME}" < "$LATEST"

# 3. Verify — expect a realistic table count and at least one row in oc_users
docker exec test-restore-nextcloud mariadb \
  -u "${NEXTCLOUD_DB_USER}" -p"${NEXTCLOUD_DB_PASSWORD}" "${NEXTCLOUD_DB_NAME}" \
  -e "SHOW TABLES;" | wc -l
docker exec test-restore-nextcloud mariadb \
  -u "${NEXTCLOUD_DB_USER}" -p"${NEXTCLOUD_DB_PASSWORD}" "${NEXTCLOUD_DB_NAME}" \
  -e "SELECT COUNT(*) FROM oc_users;"

# 4. Clean up
docker rm -f test-restore-nextcloud
```

Last verified: 104 tables, 1 row in `oc_users` — clean restore.

## Immich (PostgreSQL / pgvecto.rs-VectorChord bridge)

```bash
# 1. Throwaway Postgres container using the SAME image as production —
#    the extension set matters for a valid restore, a plain postgres image
#    will not have pgvecto.rs/VectorChord available.
docker run -d --name test-restore-immich \
  -e POSTGRES_USER="${IMMICH_DB_USER}" \
  -e POSTGRES_PASSWORD="${IMMICH_DB_PASSWORD}" \
  -e POSTGRES_DB="${IMMICH_DB_NAME}" \
  ghcr.io/immich-app/postgres:16-vectorchord0.3.0-pgvectors0.3.0

sleep 15

# 2. Restore
LATEST=$(ls -t /root/backups/immich_*.dump | head -1)
docker exec -i test-restore-immich pg_restore \
  -U "${IMMICH_DB_USER}" -d "${IMMICH_DB_NAME}" --clean --if-exists < "$LATEST"

# 3. Verify — note the users table is literally named "user" (reserved word,
#    needs quoting)
docker exec test-restore-immich psql -U "${IMMICH_DB_USER}" -d "${IMMICH_DB_NAME}" -c '\dt' | wc -l
docker exec test-restore-immich psql -U "${IMMICH_DB_USER}" -d "${IMMICH_DB_NAME}" -c 'SELECT COUNT(*) FROM "user";'

# 4. Clean up
docker rm -f test-restore-immich
```

Last verified: 76 tables, 1 row in `"user"` — clean restore.

## What this does and doesn't prove

This confirms the SQL/dump itself is structurally valid and restorable. It does **not** exercise application-level file storage (Nextcloud's actual files under `/mnt/gluster/nextcloud/html`, Immich's actual photo/video blobs under `/mnt/gluster/immich/upload`) — those live entirely on GlusterFS and are protected by its own replication, independent of these database backups. A full disaster-recovery drill covering both the database and the GlusterFS-resident files together has not yet been performed and is a natural next step.
