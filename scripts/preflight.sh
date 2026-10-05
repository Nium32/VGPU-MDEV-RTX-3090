#!/bin/bash
# Report what this machine looks like to the vGPU scripts, and flag anything that
# will stop them working. Changes nothing. Run it first, on any new machine.
#
# Exit status: 0 everything looks usable, 1 at least one hard problem.

. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"

problems=0
note_problem() { problems=$((problems+1)); }

say "config"
info "config file   : ${VGPU_CONF_USED:-none found, using built-in defaults}"
info "VGPU_ROOT     : $VGPU_ROOT $([ -d "$VGPU_ROOT" ] && echo '(exists)' || echo '(MISSING)')"
info "VM_BASE       : $VM_BASE $([ -d "$VM_BASE" ] && echo '(exists)' || echo '(missing)')"
[ -d "$VGPU_ROOT" ] || note_problem

say "host"
info "kernel        : $(uname -r)"
info "distribution  : $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown)"
info "qemu          : $(have qemu-system-x86_64 && qemu-system-x86_64 --version | head -1 || echo 'NOT INSTALLED')"
have qemu-system-x86_64 || note_problem
check_kernel || note_problem
check_iommu  || note_problem
check_modeset_absent || note_problem

say "gpu"
BDF=$(detect_gpu_bdf) || exit 1
info "pci address   : $BDF"
info "pci id        : $(gpu_pci_id "$BDF")"
info "iommu group   : $(gpu_iommu_group "$BDF" || echo 'none - IOMMU is off')"
info "bound driver  : $(bound_driver "$BDF" || echo 'none')"
if have lspci; then
    info "description   : $(lspci -s "$BDF" | cut -d' ' -f2-)"
    info "bar sizes     : $(lspci -v -s "$BDF" 2>/dev/null | awk '/Memory at/{printf "%s ", $NF}')"
fi
# The spoof only has to convince the userspace daemons, so the kernel driver
# keeps seeing the real device id. Seeing the real id here is correct.
info "note          : the id above is the REAL one; the vGPU daemons are what"
info "                get told something else, via LD_PRELOAD"

say "driver and modules"
if MDIR=$(module_dir); then
    info "module dir    : $MDIR"
    for m in nvidia nvidia-vgpu-vfio nvidia-uvm; do
        if [ -f "$MDIR/$m.ko" ]; then
            info "  $m.ko  version=$(modinfo -F version "$MDIR/$m.ko" 2>/dev/null) vermagic=$(modinfo -F vermagic "$MDIR/$m.ko" 2>/dev/null | awk '{print $1}')"
        else
            warn "  $m.ko MISSING from $MDIR"; note_problem
        fi
    done
else
    warn "no module tree for the running kernel at $VGPU_ROOT/driver/modules-$(uname -r)"
    warn "a module built for another kernel cannot be used: insmod rejects the version magic"
    note_problem
fi

say "required helper modules"
for h in zfmulti mdguest; do
    if ko=$(helper_ko "$h"); then
        info "$h        : $ko"
    else
        warn "$h MISSING or built for the wrong kernel. Build it: make -C $VGPU_ROOT/kmod/$h"
        note_problem
    fi
done
info "zfmulti spec  : $ZFMULTI_SPEC"
info "                this offset is specific to one driver build. If you are not"
info "                on 535.309.01 it is almost certainly wrong for you."

say "firmware"
if OVMF=$(detect_ovmf); then
    info "ovmf code     : $OVMF"
else
    warn "no 4MB OVMF image found. Install edk2-ovmf (or ovmf) and set OVMF_CODE."
    note_problem
fi

say "vgpu profiles offered by this card"
if list_vgpu_types "$BDF"; then
    if T=$(resolve_vgpu_type "$BDF"); then
        info "selected      : $T  ($(cat "$(mdev_types_dir "$BDF")/$T/name" 2>/dev/null))"
        info "available     : $(cat "$(mdev_types_dir "$BDF")/$T/available_instances" 2>/dev/null)"
    else
        warn "none of VGPU_PROFILE_NAME / VGPU_TYPE matched. Pick one from the list above."
        note_problem
    fi
else
    warn "no profiles registered. Start nvidia-vgpud and nvidia-vgpu-mgr, then re-run."
    note_problem
fi

say "display"
# The vgpu-kvm RM core registers no KMS connectors, so this host cannot drive a
# monitor from this GPU. Reported here so it is not mistaken for a fault.
# Scope to THIS gpu. Counting /sys/class/drm/card*/ would include a second
# card that is driving the monitor, and the note below would never print.
conn=$(ls -d /sys/bus/pci/devices/$BDF/drm/card*/card*-* 2>/dev/null | wc -l)
info "drm connectors on this GPU: $conn"
[ "$conn" -eq 0 ] && info "                expected: a vGPU host has no scanout. Use a second GPU for a monitor."

echo
if [ "$problems" -eq 0 ]; then
    say "preflight OK"
else
    say "preflight found $problems problem(s) - fix those before running bringup.sh"
fi
if [ "$problems" -eq 0 ]; then
    exit 0
fi
exit 1
