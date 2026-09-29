#!/bin/bash
# Install to /usr/local/bin/wait-for-tailscale.sh (chmod +x) on every
# GlusterFS peer node. Used by wait-for-tailscale.service.
#
# Deliberately checks for a real IP on the tailscale0 interface rather than
# parsing `tailscale status --json` — the JSON's top-level "Online" field
# reflects peer reachability for every node in the tailnet, not specifically
# "is *this* node's own interface actually up", and matching "Self" against
# it reliably requires a real JSON parser rather than grep across
# pretty-printed multi-line output. Checking the interface directly is both
# simpler and more precisely answers the question this script needs to ask.

MAX_WAIT=60
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
        echo "Tailscale is online after ${WAITED}s"
        exit 0
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

echo "ERROR: Tailscale did not come online within ${MAX_WAIT}s"
exit 1
