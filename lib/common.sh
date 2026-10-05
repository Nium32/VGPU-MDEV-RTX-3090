#!/bin/bash
# Shared configuration, auto-detection and sanity checks.
# Source this from every script:   . "$(dirname "$0")/../lib/common.sh"
#
# Nothing in here changes system state. It reads sysfs, applies defaults and
# refuses to continue when something required is missing.

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_here/.." && pwd)"

for _cfg in "$VGPU_CONF" "$REPO_ROOT/vgpu.conf" /etc/vgpu.conf; do
    if [ -n "$_cfg" ] && [ -r "$_cfg" ]; then
        # shellcheck disable=SC1090
        . "$_cfg"
        VGPU_CONF_USED="$_cfg"
        break
    fi
done

VGPU_ROOT="${VGPU_ROOT:-/srv/vgpu/VMs}"
VM_BASE="${VM_BASE:-/var/lib/vgpu-vm}"
LOG_DIR="${LOG_DIR:-/var/log/vgpu}"
VGPU_PARAMS="${VGPU_PARAMS:-loglevel=5,disable_vnc=1}"
NVIDIA_REGISTRY_DWORDS="${NVIDIA_REGISTRY_DWORDS:-RMSetSriovMode=0}"
NVIDIA_ENABLE_GPU_FIRMWARE="${NVIDIA_ENABLE_GPU_FIRMWARE:-0}"
ZFMULTI_SPEC="${ZFMULTI_SPEC:-_nv042311rm+0x28:1}"
VM_NAME="${VM_NAME:-winguest}"
VM_DISK="${VM_DISK:-win.qcow2}"
VM_MEM_MB="${VM_MEM_MB:-12288}"
VM_CORES="${VM_CORES:-4}"
VM_THREADS="${VM_THREADS:-2}"
RDP_HOST_PORT="${RDP_HOST_PORT:-3390}"
QEMU_VNC_DISPLAY="${QEMU_VNC_DISPLAY:-2}"
KERNEL_KNOWN_GOOD="${KERNEL_KNOWN_GOOD:-5.15.95 6.1.71}"
VGPU_PROFILE_NAME="${VGPU_PROFILE_NAME:-}"
VGPU_TYPE="${VGPU_TYPE:-}"

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

say()  { echo "== $*"; }
info() { echo "   $*"; }
warn() { echo "!! $*" >&2; }
die()  { echo "XX $*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root (or via sudo)"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# GPU discovery
# ---------------------------------------------------------------------------

# First NVIDIA display controller, domain-qualified. Honours GPU_BDF if set.
detect_gpu_bdf() {
    if [ -n "$GPU_BDF" ]; then
        [ -d "/sys/bus/pci/devices/$GPU_BDF" ] || die "GPU_BDF=$GPU_BDF does not exist in sysfs"
        echo "$GPU_BDF"; return
    fi
    local found
    found=$(lspci -D -d '10de::0300' 2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$found" ] || die "no NVIDIA display controller found; set GPU_BDF in vgpu.conf"
    echo "$found"
}

# Real vendor:device of the card, straight from sysfs rather than a cached guess.
gpu_pci_id() {
    local bdf="$1" v d
    v=$(cat "/sys/bus/pci/devices/$bdf/vendor" 2>/dev/null)
    d=$(cat "/sys/bus/pci/devices/$bdf/device" 2>/dev/null)
    echo "${v#0x}:${d#0x}"
}

# IOMMU group number. Needed because a SIGKILLed qemu can wedge the group and
# the recovery path has to name it.
gpu_iommu_group() {
    local l
    l=$(readlink -f "/sys/bus/pci/devices/$1/iommu_group" 2>/dev/null)
    [ -n "$l" ] && basename "$l"
}

# Always address mdev types through /sys/bus/pci/devices/<bdf>/, never through a
# /sys/devices/pci0000:00/<bridge>/<bdf>/ path. The bridge component differs on
# every board and hard-coding it is what makes a script machine-specific.
mdev_types_dir() {
    echo "/sys/bus/pci/devices/$1/mdev_supported_types"
}

# Resolve a profile NAME ("RTXA5000-8Q") to its nvidia-NNN type directory.
# The numeric id is not stable across driver versions or boards; the name is.
resolve_vgpu_type() {
    local bdf="$1" dir t name
    dir=$(mdev_types_dir "$bdf")
    [ -d "$dir" ] || return 1

    if [ -n "$VGPU_PROFILE_NAME" ]; then
        for t in "$dir"/*; do
            [ -r "$t/name" ] || continue
            name=$(cat "$t/name")
            if [ "$name" = "$VGPU_PROFILE_NAME" ] || [ "${name##* }" = "$VGPU_PROFILE_NAME" ]; then
                basename "$t"; return 0
            fi
        done
        warn "profile name '$VGPU_PROFILE_NAME' not offered by this card"
    fi

    if [ -n "$VGPU_TYPE" ] && [ -d "$dir/$VGPU_TYPE" ]; then
        echo "$VGPU_TYPE"; return 0
    fi
    return 1
}

list_vgpu_types() {
    local dir t
    dir=$(mdev_types_dir "$1")
    [ -d "$dir" ] || { warn "no mdev types registered yet (is nvidia-vgpu-mgr running?)"; return 1; }
    for t in "$dir"/*; do
        [ -r "$t/name" ] || continue
        printf '   %-14s %-26s fb=%-8s avail=%s\n' \
            "$(basename "$t")" \
            "$(cat "$t/name" 2>/dev/null)" \
            "$(cat "$t/description" 2>/dev/null | tr ',' '\n' | grep -i framebuffer | tr -d ' ' | cut -d= -f2)" \
            "$(cat "$t/available_instances" 2>/dev/null)"
    done
}

# ---------------------------------------------------------------------------
# module set for the running kernel
# ---------------------------------------------------------------------------

# A module built for one kernel cannot load on another: insmod fails on version
# magic. So the tree is per-kernel and there is no generic fallback worth having.
module_dir() {
    local d="$VGPU_ROOT/driver/modules-$(uname -r)"
    [ -d "$d" ] || return 1
    echo "$d"
}

# Prefer name-<uname -r>.ko, accept name.ko, and verify vermagic before use so a
# mismatch is a clear message instead of a bare "Invalid module format".
helper_ko() {
    local name="$1" kv; kv=$(uname -r)
    local c="$VGPU_ROOT/kmod/$name/$name-$kv.ko"
    [ -f "$c" ] || c="$VGPU_ROOT/kmod/$name/$name.ko"
    [ -f "$c" ] || return 1
    if have modinfo; then
        local vm; vm=$(modinfo -F vermagic "$c" 2>/dev/null | awk '{print $1}')
        if [ -n "$vm" ] && [ "$vm" != "$kv" ]; then
            warn "$name was built for $vm, running kernel is $kv - it will not load"
            return 2
        fi
    fi
    echo "$c"
}

# ---------------------------------------------------------------------------
# firmware
# ---------------------------------------------------------------------------

# The 4MB OVMF code image, wherever this distribution keeps it. Must be the 4MB
# variant: these VMs carry a 4MB OVMF_VARS.fd and the two sizes must match.
detect_ovmf() {
    [ -n "$OVMF_CODE" ] && { [ -r "$OVMF_CODE" ] || die "OVMF_CODE=$OVMF_CODE unreadable"; echo "$OVMF_CODE"; return; }
    local c
    for c in \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.4m.fd \
        /usr/share/qemu/ovmf-x86_64-code.bin \
        /usr/share/edk2/ovmf/OVMF_CODE.fd
    do
        [ -r "$c" ] && { echo "$c"; return; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# sanity
# ---------------------------------------------------------------------------

check_kernel() {
    local kv base ok=0 g
    kv=$(uname -r); base=${kv%%-*}
    for g in $KERNEL_KNOWN_GOOD; do [ "$base" = "$g" ] && ok=1; done
    if [ "$ok" != 1 ]; then
        warn "kernel $kv is NOT in the known-good list ($KERNEL_KNOWN_GOOD)."
        warn "Kernels outside that list have failed here with thousands of"
        warn "'Immediate pteblit ... timed out' messages from nvidia-vgpu-mgr."
        warn "The stack will still load and the guest will still boot; it just"
        warn "will not work. See docs/KERNEL-REQUIREMENTS.md."
        return 1
    fi
    return 0
}

check_iommu() {
    if [ ! -d /sys/class/iommu ] || [ -z "$(ls -A /sys/class/iommu 2>/dev/null)" ]; then
        warn "no IOMMU exposed. vfio mdev needs it: add intel_iommu=on or amd_iommu=on"
        return 1
    fi
    return 0
}

# nvidia_drm and nvidia_modeset pin nvidia.ko, and on this stack nvidia_modeset
# cannot be unloaded again once it has spun up: its refcount never drops and the
# only exit is a reboot. Catch it before anything else touches the GPU.
check_modeset_absent() {
    if lsmod | grep -qE '^nvidia_(drm|modeset) '; then
        warn "nvidia_drm/nvidia_modeset are loaded. They pin nvidia.ko, and"
        warn "nvidia_modeset often cannot be unloaded again without a reboot."
        warn "Blacklist them before using this stack."
        return 1
    fi
    return 0
}
