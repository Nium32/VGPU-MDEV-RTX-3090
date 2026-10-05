#!/bin/bash
# Create a fresh mdev from the configured profile and boot the guest on it.
#
# Usage: startguest.sh [vgpu_params]
#   vgpu_params defaults to $VGPU_PARAMS from vgpu.conf.
#
# A note on the disk: the guest boots $VM_BASE/$VM_NAME/$VM_DISK. If that image
# is an overlay on a backing file, do not also boot the backing file read-write
# from another script. QEMU's locking stops both being open at once, but nothing
# stops you doing it sequentially, and that silently invalidates the overlay.

set +e
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
need_root

VGP="${1:-$VGPU_PARAMS}"
D="$VM_BASE/$VM_NAME"

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"
command -v uuidgen >/dev/null || die "uuidgen not installed (util-linux)"
[ -d "$D" ] || die "guest directory $D does not exist"
[ -f "$D/$VM_DISK" ] || die "disk $D/$VM_DISK does not exist"
[ -f "$D/OVMF_VARS.fd" ] || die "$D/OVMF_VARS.fd missing; copy the 4MB OVMF vars template in"

OVMF=$(detect_ovmf) || die "no 4MB OVMF code image found; set OVMF_CODE in vgpu.conf"
BDF=$(detect_gpu_bdf) || exit 1
TYPE=$(resolve_vgpu_type "$BDF") || die "no vGPU profile resolved; run preflight.sh"
TDIR=$(mdev_types_dir "$BDF")

avail=$(cat "$TDIR/$TYPE/available_instances" 2>/dev/null)
[ "${avail:-0}" -lt 1 ] && die "profile $TYPE has no instances left (available_instances=$avail)"

mkdir -p "$LOG_DIR"

U=$(uuidgen)
say "creating mdev $U on $BDF as $TYPE ($(cat "$TDIR/$TYPE/name" 2>/dev/null))"
echo "$U" > "$TDIR/$TYPE/create" || die "mdev create failed"
sleep 3
[ -e "/sys/bus/mdev/devices/$U" ] || die "mdev $U did not appear"

echo "$VGP" > "/sys/bus/mdev/devices/$U/nvidia/vgpu_params" \
    || warn "could not set vgpu_params"
info "vgpu_params: $VGP"

# Journal mark, so the health checks can scope their greps to this run only.
date '+%Y-%m-%d %H:%M:%S' > /tmp/vgpu-mark.txt

rm -f "$D/monitor.sock"

VNC_ARG=()
[ "${QEMU_VNC_DISPLAY:--1}" -ge 0 ] && VNC_ARG=(-vga std -vnc "0.0.0.0:$QEMU_VNC_DISPLAY")

NET_ARG=(-netdev user,id=net0 -device e1000e,netdev=net0)
if [ "${RDP_HOST_PORT:-0}" -gt 0 ]; then
    NET_ARG=(-netdev "user,id=net0,hostfwd=tcp::$RDP_HOST_PORT-:3389" -device e1000e,netdev=net0)
    info "forwarding host port $RDP_HOST_PORT to guest 3389"
fi

say "booting $VM_NAME"
qemu-system-x86_64 -name "$VM_NAME" -uuid "$U" \
    -machine q35,accel=kvm,hpet=off \
    -smp "sockets=1,cores=$VM_CORES,threads=$VM_THREADS" -m "$VM_MEM_MB" \
    -rtc base=localtime,driftfix=slew -global kvm-pit.lost_tick_policy=discard \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF" \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -cpu host,kvm=on,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_synic,hv_stimer \
    "${VNC_ARG[@]}" \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
    -device "vfio-pci,sysfsdev=/sys/bus/mdev/devices/$U,enable-migration=off" \
    -boot menu=off -monitor "unix:$D/monitor.sock,server,nowait" \
    -device ich9-ahci,id=ahci \
    -drive "file=$D/$VM_DISK,if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap" \
    -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
    "${NET_ARG[@]}" \
    >> "$LOG_DIR/$VM_NAME-qemu.log" 2>&1 &

sleep 15
running=$(pgrep -cf "qemu-system-x86_64.*$VM_NAME")
info "mdev=$U  qemu processes=$running"
if [ "$running" -eq 0 ]; then
    warn "qemu exited. Last lines of $LOG_DIR/$VM_NAME-qemu.log:"
    tail -5 "$LOG_DIR/$VM_NAME-qemu.log" | cut -c1-200 | sed 's|^|     |'
    warn "removing the orphaned mdev"
    echo 1 > "/sys/bus/mdev/devices/$U/remove" 2>/dev/null
    exit 1
fi
say "up. monitor: socat - UNIX-CONNECT:$D/monitor.sock"
