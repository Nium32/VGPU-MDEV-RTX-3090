#!/bin/bash
# pve-vgpu-portmap.sh - publish each running vGPU guest's RDP port on the LAN.
#
# The guests live on an isolated bridge (10.10.10.0/24) that the LAN cannot reach.
# This DNATs a port on the host to each guest's RDP port, so a LAN client connects
# to <host-ip>:<port> instead of needing an SSH tunnel.
#
#   port = 13289 + vmid           so VM 100 -> 13389, 101 -> 13390, 102 -> 13391
#
# All rules live in a dedicated VGPURDP chain, so this is idempotent: the chain is
# rebuilt from scratch every run and removing the chain removes every rule.
#
# SECURITY: this exposes Windows RDP to the local network. Use strong guest
# passwords. Do not forward these ports from the router to the internet.
set -euo pipefail

# The timer can fire while a manual run is between the flush and the appends,
# which duplicates rules. Take an exclusive lock and re-exec under it.
LOCK=/run/vgpu-portmap.lock
if [ "${VGPU_PORTMAP_LOCKED:-}" != "1" ]; then
    export VGPU_PORTMAP_LOCKED=1
    exec flock -w 30 "$LOCK" "$0" "$@"
fi

LEASES=${LEASES:-/var/lib/misc/dnsmasq.leases}
CHAIN=VGPURDP

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# Build the chain fresh. -N fails harmlessly if it already exists.
iptables -t nat -N "$CHAIN" 2>/dev/null || true
iptables -t nat -F "$CHAIN"
# Attach it to PREROUTING exactly once.
iptables -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null \
    || iptables -t nat -I PREROUTING 1 -j "$CHAIN"

n=0
for conf in /etc/pve/qemu-server/*.conf; do
    [ -e "$conf" ] || continue
    vmid=$(basename "$conf" .conf)

    # Only guests that actually have a vGPU attached.
    grep -q '^hostpci0:.*mdev=' "$conf" || continue
    # Only while running - a stopped guest has no lease and no listener.
    qm status "$vmid" 2>/dev/null | grep -q running || continue

    mac=$(sed -n 's/^net0: .*=\([0-9A-Fa-f:]*\),bridge.*/\1/p' "$conf" | head -1)
    [ -n "$mac" ] || continue

    ip=$(grep -i " ${mac} " "$LEASES" 2>/dev/null | awk '{print $3}' | tail -1)
    [ -n "$ip" ] || continue          # no lease yet: guest still booting

    port=$(( 13289 + vmid ))
    iptables -t nat -A "$CHAIN" -p tcp --dport "$port" -j DNAT --to-destination "$ip:3389"
    echo "  vm$vmid  ${mac}  ${ip}:3389  <-  *:${port}"
    n=$((n+1))
done

echo "published $n guest(s)"