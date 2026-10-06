#!/bin/bash
# vgpu-recover.sh [vmid...]   recover the vGPU stack after an Xid / wedged mdev.
#
# Symptoms this clears:
#   - a guest will not start: "error getting device from group N: Input/output error"
#     or "[nvidia-vgpu-vfio] <uuid>: start failed. status: 0x1"
#   - "Immediate pteblit ... timed out" / "Failed to push PTE blit request" repeating
#   - a guest still shown as running but unreachable after an Xid
#
# The stack cannot be reloaded while any guest holds an mdev, so every guest is
# stopped first, leftover mdevs are reaped, the stack is reloaded, and the guests
# are started again one at a time - starting them together is what tends to fail.
set -euo pipefail

BRINGUP=${BRINGUP:-/opt/vgpu-scripts/scripts/bringup.sh}
VGPU_CONF=${VGPU_CONF:-/etc/vgpu.conf}
GPU_BDF=${GPU_BDF:-$(lspci -Dn -d 10de: 2>/dev/null | awk '$2 ~ /^0300/ {print $1; exit}')}
MDEV_TYPE=${MDEV_TYPE:-nvidia-664}

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# Which guests to bring back: those given, else every one that has a vGPU attached.
if [ "$#" -gt 0 ]; then
    GUESTS=("$@")
else
    mapfile -t GUESTS < <(grep -ls '^hostpci0:.*mdev=' /etc/pve/qemu-server/*.conf 2>/dev/null \
                          | xargs -r -n1 basename | sed 's/\.conf$//' | sort -n)
fi
echo "guests in scope: ${GUESTS[*]:-none}"

echo "== recent Xid =="
dmesg | grep -i 'Xid' | tail -3 | sed 's/^/   /' || echo "   none"

echo "== stopping guests =="
for v in "${GUESTS[@]:-}"; do
    [ -n "$v" ] || continue
    [ -e "/etc/pve/qemu-server/$v.conf" ] || continue
    qm shutdown "$v" --timeout 60 >/dev/null 2>&1 || true
done
for v in "${GUESTS[@]:-}"; do
    [ -n "$v" ] || continue
    for _ in $(seq 1 35); do
        [ "$(qm status "$v" 2>/dev/null)" = "status: stopped" ] && break
        sleep 2
    done
    # A guest wedged by an Xid will not answer ACPI; it has to be killed.
    [ "$(qm status "$v" 2>/dev/null)" = "status: stopped" ] || qm stop "$v" >/dev/null 2>&1 || true
    echo "   vm$v: $(qm status "$v" 2>/dev/null)"
done

echo "== reaping leftover mdevs =="
for d in /sys/bus/mdev/devices/*/; do
    [ -e "$d" ] || continue
    echo 1 > "${d}remove" 2>/dev/null || true
    echo "   removed $(basename "$d")"
done
sleep 2

echo "== reloading the stack =="
VGPU_CONF="$VGPU_CONF" "$BRINGUP" 2>&1 | tail -8 | sed 's/^/   /'

avail=$(cat "/sys/bus/pci/devices/$GPU_BDF/mdev_supported_types/$MDEV_TYPE/available_instances" 2>/dev/null || echo 0)
echo "   $MDEV_TYPE available: $avail"
[ "${avail:-0}" -ge 1 ] || { echo "stack came back with no free instances - not starting guests" >&2; exit 1; }

echo "== starting guests, one at a time =="
for v in "${GUESTS[@]:-}"; do
    [ -n "$v" ] || continue
    [ -e "/etc/pve/qemu-server/$v.conf" ] || continue
    qm start "$v" >/dev/null 2>&1 || true
    sleep 20
    echo "   vm$v: $(qm status "$v" 2>/dev/null)"
done

echo "== result =="
echo "   Xid count now: $(dmesg | grep -ci xid || true)"
echo "   mdevs: $(find /sys/bus/mdev/devices -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"