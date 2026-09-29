# Incident 02 — Immich Breaking Database Extension Migration

## Summary

As part of recovering from [Incident 01](01-swarm-cert-expiry-and-recovery.md), redeploying the Immich stack failed. The `immich-server` container crash-looped immediately on startup with no vector search extension it recognized. Root cause: `immich-server` was pinned to a floating `:release` tag, which — having not been redeployed in months — pulled a current release that had **entirely dropped support** for the `pgvecto.rs` extension the existing database was built on, in favor of its successor, VectorChord. There was no compatibility shim; the new server flatly refused to start against the old database.

## Symptoms (in order encountered)

1. `immich-server` container: `Error: No vector extension found. Available extensions: vchord, vector` — repeated crash loop, `docker service ps` showing `Rejected`/`Failed` in a cycle.
2. `immich-db` (unchanged, still `tensorchord/pgvecto-rs:pg16-v0.3.0`) confirmed healthy and accepting connections independently (`pg_isready` → `accepting connections`) — ruling out a database-availability problem and pointing squarely at an application/extension incompatibility.
3. Direct inspection (`\dx` in psql) confirmed the database's only vector extension was `vectors` v0.3.0 (the pgvecto.rs extension) — nothing the new server recognized.

## Diagnosis

Research into Immich's own release notes (checked directly rather than assumed) confirmed: the migration path from `pgvecto.rs` to VectorChord was introduced at Immich `v1.133.0`, via a documented database-image swap (`tensorchord/pgvecto-rs:pg16-v0.3.0` → `ghcr.io/immich-app/postgres:16-vectorchord0.3.0-pgvectors0.3.0`, a "bridge" image carrying both extensions). Versions *before* `v1.133.0` still work directly against the old `pgvecto.rs` image with zero changes. Versions from some point after `v1.133.0` (confirmed: the version originally pulled via `:release`) drop `pgvecto.rs` support entirely — no compatibility mode, no automatic bridging, just a hard failure.

This meant a **direct jump from the old database image straight to the current release was not a viable path at all** — the current release doesn't know how to talk to the old extension, and doesn't offer any way to trigger the migration itself.

## Recovery — staged migration

Before touching anything: took a manual `pg_dump` of the Immich database to a separate file, independent of the automated nightly backup, specifically because this was an unusually risky operation.

1. **Step back, not forward**: pinned `immich-server` to `v1.132.3` (the last version confirmed to work directly against `pgvecto.rs` with zero database changes), to first confirm the *server* itself wasn't the sole problem.
   - Result: new failure — `corrupted migrations: previously executed migration ... is missing`. The earlier crash-looping `:release` container had, in its brief startup attempts before failing on the vector-extension check, already partially applied one or two newer database migrations that `v1.132.3`'s migration history doesn't know about. Stepping backward in server version was no longer clean either.

2. **Swap the database image** to the bridge image (`ghcr.io/immich-app/postgres:16-vectorchord0.3.0-pgvectors0.3.0`) and bump `immich-server` to exactly `v1.133.0` — the first version designed to perform this specific migration automatically on startup.
   - Logs confirmed the migration running: `Reindexed face_index`, `Reindexed clip_index`, `Dropping pgvecto.rs extension` — real progress.
   - Then hit the *same* "corrupted migrations" error again, for a different (newer) missing migration ID — the crash-looping `:release` attempts had reached slightly further into the future migration history than `v1.133.0` itself knows about.

3. **Move forward to `:release`** (now safe, since the database had the extension the current release actually expects): this time, `immich-server` started cleanly, applied every remaining migration including the ones that had confused the two older versions, and came up healthy — confirmed via `docker service logs` showing `Nest application successfully started` and `Immich Microservices is running`.

## Key takeaway

A version-pinned service that hasn't been touched in months, sitting behind a floating tag on its *dependency*, can accumulate a gap wide enough that there's no single safe upgrade step across it — the correct fix is not "roll back" or "push forward blindly," but **stage through the exact version boundary where the breaking change was introduced**, verifying at each step. This incident is the direct reason for the [image versioning policy](../architecture.md#image-versioning-policy): pin every image to an explicit version or digest, so an update is always a deliberate, single, plannable step rather than an unplanned multi-version jump discovered mid-incident.

## Verification

- Restore-tested independently afterward (see [disaster-recovery-restore.md](../runbooks/disaster-recovery-restore.md)): the automated nightly Immich backup restored cleanly into an isolated, disposable container — 76 tables, correct row counts on the `user` table — confirming the backup pipeline itself was unaffected by any of this.
