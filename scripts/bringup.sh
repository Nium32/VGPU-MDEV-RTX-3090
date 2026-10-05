#!/bin/bash
# Bring the vGPU host stack up from nothing.
#
# The order matters and is not arbitrary:
#   nvidia.ko
#     -> nvidia-vgpud          configures RM; this is where the device-id spoof applies
#     -> nvidia-vgpu-vfio.ko
#     -> nvidia-uvm.ko         only needed if you also want CUDA on the host
#     -> kprobe helpers        zfmulti is required, see below
#     -> nvidia-vgpu-mgr       this is what actually registers the mdev types
#
# A PCI function-level reset is mandatory after any by-hand reload. Without it
# the first guest fails at init_device_instance with error 7.
#
# Nothing here is specific to one machine: the GPU address, its IOMMU group, the
# module set and the profile are all discovered at runtime.

set +e
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
need_root

mkdir -p "$LOG_DIR"
# tee, not plain redirect: with a plain redirect every die() and warn() goes
# only to the log and the operator sees a silent prompt return.
exec > >(tee -a "$LOG_DIR/bringup.log") 2>&1

echo "================ $(date '+%F %T') bring-up ================"

BDF=$(detect_gpu_bdf) || exit 1
GROUP=$(gpu_iommu_group "$BDF")
info "gpu $BDF  pci-id $(gpu_pci_id "$BDF")  iommu group ${GROUP:-unknown}"

check_kernel
check_modeset_absent || die "refusing to continue with nvidia_modeset loaded"

MDIR=$(module_dir) || die "no module tree for kernel $(uname -r) under $VGPU_ROOT/driver/"
for m in nvidia nvidia-vgpu-vfio; do
    [ -f "$MDIR/$m.ko" ] || die "$MDIR/$m.ko missing"
done
info "modules from $MDIR"

say "tear down whatever is running"
# SIGKILL leaves the IOMMU group wedged; qemu releases the vfio device on TERM.
pkill -TERM -f "qemu-system.*$VM_NAME" 2>/dev/null
for _i in $(seq 1 20); do pgrep -f "qemu-system.*$VM_NAME" >/dev/null || break; sleep 1; done
pgrep -f "qemu-system.*$VM_NAME" >/dev/null && { warn "guest did not exit on TERM, forcing"; pkill -KILL -f "qemu-system.*$VM_NAME"; sleep 3; }
for _m in /sys/bus/mdev/devices/*; do
    [ -e "$_m" ] || continue
    _m=${_m##*/}
    # Writing remove on an mdev that a live qemu still has open blocks in
    # vfio_unregister_group_dev, and the retry there is uninterruptible, so
    # even timeout cannot get us back.
    if grep -lqs "$_m" /proc/[0-9]*/cmdline 2>/dev/null; then
        warn "mdev $_m is in use by a live process, leaving it alone"
        continue
    fi
    timeout 30 sh -c "echo 1 > /sys/bus/mdev/devices/$_m/remove" 2>/dev/null
done
systemctl stop nvidia-vgpu-mgr nvidia-vgpud 2>/dev/null
rmmod zfmulti mdguest 2>/dev/null
for m in nvidia_uvm nvidia_vgpu_vfio nvidia; do
    lsmod | grep -q "^$m " && rmmod "$m" 2>&1 | sed 's|^|     |'
done
left=$(lsmod | grep -c '^nvidia')
info "nvidia modules still loaded: $left"
[ "$left" -ne 0 ] && die "refusing to reset the GPU while nvidia modules are loaded"

say "pci function-level reset"
safe_to_reset "$BDF" || die "refusing to reset $BDF while a driver is bound to it"
if echo 1 > "/sys/bus/pci/devices/$BDF/reset" 2>/dev/null; then
    info "reset ok"
else
    warn "reset failed; the first guest will probably fail with error 7"
fi
sleep 3

# nvidia-vgpu-vfio.ko links against these. Without them insmod fails with
# "Unknown symbol in module" and the message does not say which symbol.
say "vfio prerequisites"
modprobe -a mdev vfio vfio_pci_core irqbypass 2>&1 | sed 's|^|     |'
for m in mdev vfio vfio_pci_core irqbypass; do
    printf '     %-16s %s\n' "$m" "$(lsmod | grep -cE "^$m ")"
done

say "1. nvidia.ko"
insmod "$MDIR/nvidia.ko" \
    NVreg_RegistryDwords="$NVIDIA_REGISTRY_DWORDS" \
    NVreg_EnableGpuFirmware="$NVIDIA_ENABLE_GPU_FIRMWARE" \
    || die "insmod nvidia.ko failed"
udevadm settle --timeout=15
info "version $(cat /sys/module/nvidia/version 2>/dev/null)"

say "2. nvidia-vgpud"
systemctl restart "$VGPUD_UNIT"; sleep 6
systemctl is-active --quiet "$VGPUD_UNIT" \n    || die "$VGPUD_UNIT did not start - check: journalctl -u $VGPUD_UNIT"
info "$VGPUD_UNIT active"

say "3. nvidia-vgpu-vfio.ko"
insmod "$MDIR/nvidia-vgpu-vfio.ko" || die "insmod nvidia-vgpu-vfio.ko failed"
udevadm settle --timeout=15; sleep 3

# Optional. Only needed for CUDA on the host alongside the guests. The device
# nodes are not created automatically when the module is insmod'ed by hand.
if [ -f "$MDIR/nvidia-uvm.ko" ]; then
    say "4. nvidia-uvm.ko (host CUDA)"
    insmod "$MDIR/nvidia-uvm.ko"
    U=$(awk '$2=="nvidia-uvm"{print $1}' /proc/devices)
    if [ -n "$U" ]; then
        mknod -m 666 /dev/nvidia-uvm       c "$U" 0 2>/dev/null
        mknod -m 666 /dev/nvidia-uvm-tools c "$U" 1 2>/dev/null
        info "/dev/nvidia-uvm major $U"
    fi
fi

# zfmulti is the single necessary intervention. The RM interrupt handler
# disables the graphics runlist and never re-enables it; forcing one branch
# makes the disable not happen. Without this the guest's graphics channel runs
# exactly once and then stalls forever, with no error anywhere.
say "5. kprobe helpers"
if ZF=$(helper_ko zfmulti); then
    insmod "$ZF" spec="$ZFMULTI_SPEC" && info "zfmulti spec=$ZFMULTI_SPEC" \
        || warn "zfmulti failed to load - the guest will stall"
else
    warn "zfmulti not available for this kernel. The stack will come up and the"
    warn "guest will boot, but its graphics channel will never run."
fi
if MG=$(helper_ko mdguest); then
    insmod "$MG" apply=1 && info "mdguest apply=1" || warn "mdguest failed to load"
else
    warn "mdguest not available for this kernel"
fi
mount -t debugfs none /sys/kernel/debug 2>/dev/null
[ -r /sys/kernel/debug/kprobes/list ] && sed 's|^|     |' /sys/kernel/debug/kprobes/list

say "6. nvidia-vgpu-mgr (registers the mdev types)"
systemctl restart "$VGPU_MGR_UNIT"; sleep 6
systemctl is-active --quiet "$VGPU_MGR_UNIT" \n    || die "$VGPU_MGR_UNIT did not start - no mdev types will be registered"
info "$VGPU_MGR_UNIT active"

echo
say "state"
TDIR=$(mdev_types_dir "$BDF")
info "kernel        : $(uname -r)"
info "nvidia        : $(cat /sys/module/nvidia/version 2>/dev/null)"
info "profiles      : $(ls "$TDIR" 2>/dev/null | wc -l)"
if T=$(resolve_vgpu_type "$BDF"); then
    info "selected      : $T ($(cat "$TDIR/$T/name" 2>/dev/null))"
    info "available     : $(cat "$TDIR/$T/available_instances" 2>/dev/null)"
else
    warn "no usable profile resolved - run preflight.sh"
fi
info "xid in dmesg  : $(dmesg | grep -ci xid)"
info "plugin errors : $(journalctl -t nvidia-vgpu-mgr --since '2 min ago' --no-pager 2>/dev/null | grep -ci 'error:')"
if [ -z "${T:-}" ]; then
    warn "no usable vGPU profile resolved - the stack is NOT ready"
    exit 1
fi
echo "================ ready ================"
