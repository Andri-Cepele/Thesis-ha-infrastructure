#!/bin/bash
# Install to /root/gluster-heal-check.sh on EVERY GlusterFS peer node
# (worker1, worker2), and schedule via cron every 2 minutes on each:
#   */2 * * * * /root/gluster-heal-check.sh
#
# Writes Prometheus textfile-collector metrics that node_exporter picks up
# automatically (see stacks/monitoring/docker-compose.yml, which mounts
# /var/lib/node_exporter/textfile_collector into the node_exporter
# container). This is how GlusterFS health becomes visible to Prometheus/
# Grafana without a dedicated GlusterFS exporter.
#
# IMPORTANT — this is the corrected version of the script. The original
# version treated ANY failure of the underlying `gluster volume heal ...`
# command (e.g. "Not able to fetch volfile from glusterd", which happens
# transiently right after glusterd restarts) as split_brain=1 via a naive
# bash fallback (`${SPLIT_BRAIN:-1}`). This produced a real, alarming
# "SPLIT-BRAIN Detected" CRITICAL email that was actually just a transient
# command failure, not a real split-brain — verified independently via
# `gluster volume heal ... info split-brain`, which reported zero real
# entries in split-brain at the same time this alert fired. The fix below
# distinguishes "the health check itself failed to run" (gluster_check_failed)
# from "the check ran and found N entries" — never assume the worst-case
# value when a check simply couldn't execute. See
# docs/incident-reports/03-failover-testing-and-boot-races.md for the full
# incident and diagnosis.
#
# Uses the absolute path to `gluster` (/usr/sbin/gluster) rather than relying
# on PATH — cron's default PATH does not include /usr/sbin, so a bare
# `gluster` call silently fails when run from cron even though it works fine
# from an interactive shell.

VOLUME_NAME="swarm-data"   # change if your volume is named differently
OUTPUT="/var/lib/node_exporter/textfile_collector/gluster_heal.prom"
TMP="${OUTPUT}.tmp"

RAW=$(/usr/sbin/gluster volume heal "$VOLUME_NAME" info summary 2>&1)
CHECK_FAILED=0

if echo "$RAW" | grep -q "Not able to fetch\|failed"; then
    CHECK_FAILED=1
    HEAL_COUNT=0
    SPLIT_BRAIN=0
else
    HEAL_COUNT=$(echo "$RAW" | grep "Number of entries in heal pending" | awk -F': ' '{sum+=$2} END {print sum}')
    SPLIT_BRAIN=$(echo "$RAW" | grep "Number of entries in split-brain" | awk -F': ' '{sum+=$2} END {print sum}')
    HEAL_COUNT=${HEAL_COUNT:-0}
    SPLIT_BRAIN=${SPLIT_BRAIN:-0}
fi

cat > "$TMP" <<EOF
# HELP gluster_heal_pending_entries Number of GlusterFS entries pending heal
# TYPE gluster_heal_pending_entries gauge
gluster_heal_pending_entries ${HEAL_COUNT}
# HELP gluster_split_brain_entries Number of GlusterFS entries in split-brain
# TYPE gluster_split_brain_entries gauge
gluster_split_brain_entries ${SPLIT_BRAIN}
# HELP gluster_check_failed Whether the gluster health check command itself failed (1=failed, 0=ok)
# TYPE gluster_check_failed gauge
gluster_check_failed ${CHECK_FAILED}
EOF

mv "$TMP" "$OUTPUT"
