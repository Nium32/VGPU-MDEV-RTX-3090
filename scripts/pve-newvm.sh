#!/bin/bash
# pve-newvm.sh [-n] <vmid> [name]
#
# Create another Windows vGPU guest as a Proxmox VM, start to finish.
#
# This exists because the manual sequence has a step that looks like a failure and
# is not: a brand new guest MUST be booted once with the vGPU attached before the
# registry fix can be applied, because Windows does not create the driver's
# display-class subkey until it has seen the card at that PCI address. That first
# boot always shows Code 43. This script does that boot, waits for Windows to come
# up, shuts it down, applies the fix and starts it for real.
#
#   -n   dry run: print every command, change nothing
#
# Defaults can be overridden from the environment.
set -euo pipefail

DRY=0
[ "${1:-}" = "-n" ] && { DRY=1; shift; }

VMID=${1:?usage: $0 [-n] <vmid> [name]}
NAME=${2:-winguest-vgpu-$VMID}

GPU_BDF=${GPU_BDF:-$(lspci -Dn -d 10de: 2>/dev/null | awk '$2 ~ /^0300/ {print $1; exit}')}
MDEV_TYPE=${MDEV_TYPE:-nvidia-664}
STORAGE=${STORAGE:-vgpussd}
STORE_DIR=${STORE_DIR:-/srv/vgpu/pve}
PARENT=${PARENT:-/var/lib/vgpu-vm/win-key0/win-key0.qcow2}
EFI_SRC=${EFI_SRC:-$STORE_DIR/images/100/vm-100-disk-1.raw}
MEM=${MEM:-12288}
CORES=${CORES:-8}
BRIDGE=${BRIDGE:-vmbr0}
FIXER=${FIXER:-/srv/vgpu/pve-fix-nvidia-regkeys.sh}
BOOT_WAIT=${BOOT_WAIT:-300}

run() {
    if [ "$DRY" = 1 ]; then printf '  %s\n' "$*"; else "$@"; fi
}

say() { printf '\n== %s\n' "$*"; }

# ---- checks that are cheap now and expensive to discover halfway through ----
[ -n "$GPU_BDF" ] || { echo "no NVIDIA VGA function found; set GPU_BDF" >&2; exit 1; }
[ -r "$PARENT" ]  || { echo "parent image not readable: $PARENT" >&2; exit 1; }
[ -r "$EFI_SRC" ] || { echo "EFI vars template not readable: $EFI_SRC" >&2; exit 1; }
[ -x "$FIXER" ]   || { echo "registry fixer not executable: $FIXER" >&2; exit 1; }
if [ -e "/etc/pve/qemu-server/$VMID.conf" ]; then
    echo "VM $VMID already exists - pick another id" >&2; exit 1
fi

AVAIL=$(cat "/sys/bus/pci/devices/$GPU_BDF/mdev_supported_types/$MDEV_TYPE/available_instances" 2>/dev/null || echo 0)
if [ "${AVAIL:-0}" -lt 1 ]; then
    echo "no $MDEV_TYPE instances free (available_instances=$AVAIL)." >&2
    echo "vGPU allows one profile type per GPU; stop a guest or pick a smaller profile." >&2
    exit 1
fi
echo "$MDEV_TYPE has $AVAIL instance(s) free; using one for VM $VMID"

IMG=$STORE_DIR/images/$VMID
UUID=$(printf '00000000-0000-0000-0000-%012d' "$VMID")

say "disks"
run install -d "$IMG"
run qemu-img create -f qcow2 -F qcow2 -b "$PARENT" "$IMG/vm-$VMID-disk-0.qcow2"
# The EFI vars are copied, not created: they already hold the Windows Boot Manager
# entry, so the guest boots Windows instead of dropping to the EFI shell.
run cp "$EFI_SRC" "$IMG/vm-$VMID-disk-1.raw"

say "define VM $VMID ($NAME)"
run qm create "$VMID" --name "$NAME" --machine q35 --bios ovmf --ostype win11 \
    --cpu host --cores "$CORES" --sockets 1 --memory "$MEM" --balloon 0 --localtime 1 \
    --scsihw virtio-scsi-single --net0 "e1000e,bridge=$BRIDGE"
# sata0, not scsi0: the image was installed on ich9-ahci and has no boot-time
# virtio-scsi driver, so virtio gives INACCESSIBLE_BOOT_DEVICE.
run qm set "$VMID" --sata0    "$STORAGE:$VMID/vm-$VMID-disk-0.qcow2,cache=writeback,discard=on"
run qm set "$VMID" --efidisk0 "$STORAGE:$VMID/vm-$VMID-disk-1.raw,efitype=4m,pre-enrolled-keys=0"
run qm set "$VMID" --boot     "order=sata0"
# pcie=1 puts it on a real PCIe root port; without it Proxmox uses the legacy bridge.
run qm set "$VMID" --hostpci0 "$GPU_BDF,mdev=$MDEV_TYPE,pcie=1"
run qm set "$VMID" --smbios1  "uuid=$UUID"

say "first boot - Code 43 here is expected and is not a failure"
run qm start "$VMID"

if [ "$DRY" = 1 ]; then
    echo "  (wait for the guest to finish booting)"
else
    mac=$(sed -n 's/^net0: .*=\([0-9A-Fa-f:]*\),bridge.*/\1/p' "/etc/pve/qemu-server/$VMID.conf" | head -1)
    echo "waiting up to ${BOOT_WAIT}s for the guest to request an address (mac $mac)"
    deadline=$((SECONDS + BOOT_WAIT)); seen=""
    while [ $SECONDS -lt $deadline ]; do
        seen=$(grep -i " ${mac} " /var/lib/misc/dnsmasq.leases 2>/dev/null | awk '{print $3}' | tail -1)
        [ -n "$seen" ] && break
        sleep 5
    done
    if [ -z "$seen" ]; then
        echo "guest never took a lease. It may still be installing devices." >&2
        echo "Finish by hand: qm stop $VMID; $FIXER $IMG/vm-$VMID-disk-0.qcow2; qm start $VMID" >&2
        exit 1
    fi
    echo "guest is up at $seen; letting device setup settle"
    sleep 45
fi

say "shut down so the registry can be edited offline"
run qm stop "$VMID"
if [ "$DRY" != 1 ]; then
    for _ in $(seq 1 30); do
        [ "$(qm status "$VMID")" = "status: stopped" ] && break
        sleep 2
    done
fi

say "apply the driver tuning keys to the subkey that first boot created"
run "$FIXER" "$IMG/vm-$VMID-disk-0.qcow2"

say "start for real"
run qm start "$VMID"

port=$(( 13289 + VMID ))
cat <<EOF

VM $VMID is up.
  RDP:    <host-ip>:$port        (the portmap timer publishes it within a minute)
  verify: the guest's Device Manager should show the vGPU with no warning icon,
          and 'nvidia-smi' in the guest should report the profile's full memory.
EOF