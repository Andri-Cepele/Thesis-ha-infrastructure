#!/bin/bash
# Install to /usr/local/bin/wait-for-gluster.sh (chmod +x) on every
# GlusterFS peer node. Used by wait-for-gluster.service.
#
# The `gluster volume start ... force` at the top is not a mistake or a
# leftover debugging step — it's the actual fix. Repeated testing showed the
# local brick process does not reliably self-start after certain reboot
# sequences (a glusterd-internal issue independent of network readiness), so
# this script force-starts it unconditionally before polling, then polls to
# confirm the LOCAL brick specifically (matched via this node's own Tailscale
# IP) is reporting Online in `gluster volume status --xml`.
#
# NOTE: MAX_WAIT is intentionally short (60s). Because the force-start above
# already addresses the actual failure mode, this loop is a safety margin for
# genuine startup latency — not a workaround for the brick never coming up.
# If this loop ever does time out in practice, that's a signal of a real
# underlying problem (e.g. disk failure) that a longer timeout would only
# mask, not fix. Investigate, don't just raise the number.

VOLUME_NAME="swarm-data"   # change if your volume is named differently
MAX_WAIT=60
WAITED=0
LOCAL_IP=$(tailscale ip -4)

# Force-start the local brick in case glusterd didn't bring it up on its own.
/usr/sbin/gluster volume start "$VOLUME_NAME" force >/dev/null 2>&1

while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(/usr/sbin/gluster volume status "$VOLUME_NAME" --xml 2>/dev/null \
        | grep -A3 "<hostname>${LOCAL_IP}<" \
        | grep "<status>1</status>")
    if [ -n "$STATUS" ]; then
        echo "Local Gluster brick is online after ${WAITED}s"
        exit 0
    fi
    sleep 3
    WAITED=$((WAITED + 3))
done

echo "ERROR: Local Gluster brick did not come online within ${MAX_WAIT}s"
exit 1
