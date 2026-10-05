#!/bin/bash
# Full stack teardown, including the vfio core modules.
#
# Why this is more than "rmmod nvidia; reset": when a qemu holding an mdev is
# killed with SIGKILL, the device's IOMMU group stays wedged. Every later qemu
# then fails with
#     error getting device from group <N> ... not already in use
# even though nothing holds /dev/vfio/<N>: no qemu process, fuser and lsof both
# show no holder, and the mdev is freshly created. Unloading the nvidia modules
# and doing a PCI reset is not enough, because vfio_iommu_type1, vfio_pci_core,
# vfio and mdev keep the group object alive. Unloading those destroys it.
#
# The group number is discovered, not assumed; it differs per machine and can
# change across reboots.
#
# Usage: hardreset.sh [NVreg_RegistryDwords value]

set +e
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
need_root

REGSTR="${1:-$NVIDIA_REGISTRY_DWORDS}"
mkdir -p "$LOG_DIR"
exec >> "$LOG_DIR/hardreset.log" 2>&1

BDF=$(detect_gpu_bdf) || exit 1
GROUP=$(gpu_iommu_group "$BDF")

echo "================ $(date '+%F %T') hard reset ================"
info "gpu $BDF, iommu group ${GROUP:-unknown}, registry '$REGSTR'"

say "kill guests and remove mdevs"
pkill -9 -f "qemu-system-x86_64" >/dev/null 2>&1; sleep 4
for m in $(ls /sys/bus/mdev/devices/ 2>/dev/null); do
    timeout 25 sh -c "echo 1 > /sys/bus/mdev/devices/$m/remove" 2>/dev/null
done
sleep 2

say "stop the vgpu daemons"
systemctl stop nvidia-vgpu-mgr.service nvidia-vgpud.service 2>/dev/null; sleep 2
pkill -9 -f nvidia-vgpu-mgr 2>/dev/null
# Anything still mapping libnvidia-vgpu will pin the modules.
for q in /proc/[0-9]*; do
    p=${q#/proc/}
    grep -ql libnvidia-vgpu "$q/maps" 2>/dev/null && kill -9 "$p" 2>/dev/null
done
sleep 3

say "unload the nvidia modules"
for t in 1 2 3 4 5; do
    rmmod zfmulti mdguest 2>/dev/null
    # nvidia_drm and nvidia_modeset pin nvidia.ko, so they must come off first.
    rmmod nvidia_drm 2>/dev/null
    rmmod nvidia_modeset 2>/dev/null
    rmmod nvidia_vgpu_vfio 2>/dev/null
    rmmod nvidia_uvm 2>/dev/null
    rmmod nvidia 2>/dev/null
    n=$(lsmod | grep -c '^nvidia')
    info "attempt $t: $n nvidia modules left"
    [ "$n" -eq 0 ] && break
    sleep 3
done
if [ "$(lsmod | grep -c '^nvidia')" -ne 0 ]; then
    warn "cannot unload the nvidia modules."
    warn "If nvidia_modeset is among them its refcount never drops on this"
    warn "stack and a reboot is the only way out."
    exit 1
fi

say "unload the vfio core so iommu group ${GROUP:-?} is destroyed"
for t in 1 2 3; do
    rmmod vfio_iommu_type1 2>/dev/null
    rmmod vfio_pci_core 2>/dev/null
    rmmod vfio 2>/dev/null
    rmmod mdev 2>/dev/null
    still=$(lsmod | grep -cE '^(vfio|vfio_pci_core|vfio_iommu_type1|mdev) ')
    info "attempt $t: $still vfio/mdev modules left"
    [ "$still" -eq 0 ] && break
    sleep 2
done
if [ -n "$GROUP" ]; then
    if [ -e "/dev/vfio/$GROUP" ]; then
        warn "/dev/vfio/$GROUP still exists; the group was not destroyed"
    else
        info "/dev/vfio/$GROUP is gone"
    fi
fi

say "pci function-level reset"
if echo 1 > "/sys/bus/pci/devices/$BDF/reset" 2>/dev/null; then
    info "reset ok"
else
    warn "reset failed"
fi
sleep 3

echo "================ reset complete; run bringup.sh ================"
